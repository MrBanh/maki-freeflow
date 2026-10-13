-- Daemon lifecycle for the freeflow plugin: probe :28180, attach a lease,
-- heartbeat it, and respawn via jobfind-or-jobstart when it is gone.
--
-- Mirrors pi-freeflow src/client.ts in simplified form:
--   probe GET /v1/models (+ /_health version check) before every action,
--   one bounded respawn retry, then an explicit proxy-down message.
-- Deliberate differences from client.ts (documented, MVP scope):
--   * The daemon runs as a scope="plugin" job, so its lifetime is bound to
--     maki's: /reload or maki exit kills it (maki owns the kill, Lua never
--     kills a busy daemon itself). Lease GC on the daemon side still retires
--     it when no client holds a lease, and every command lazily re-attaches
--     or respawns, so a reload gap self-heals on next use.
--   * No stale-version auto-replace (no busy-guarded kill from Lua):
--     a version mismatch flashes once per load telling the user to run
--     `/freeflow kill` followed by `/freeflow status`.
--   * No watchdog failed-SSE recovery, no breaker/backoff, no legacy-port
--     walk, no in-process fallback: probe-down + respawn covers it.
--
-- All functions that touch the network or jobs must run inside a
-- maki.async.spawn task (or another yieldable context), never on a
-- synchronous command-handler stack.
local M = {}

M.PORT = 28180
M.HOST = "127.0.0.1"
M.JOB_NAME = "freeflow-daemon"
M.HEARTBEAT_MS = 10000

local function config_dir()
  return maki.env.config_dir()
end

-- Optional setup override; otherwise resolve the package source or managed
-- checkout metadata. The final fallback supports old in-config installs.
local vendor_dir_override = nil
local vendor_version_cache = nil
local dependencies_ready = false
local dependencies_installing = false

-- Luau exposes debug.info; ordinary Lua uses debug.getinfo.
local source = debug and debug.info and debug.info(1, "s")
  or (debug and debug.getinfo and debug.getinfo(1, "S").source)
local package_vendor = type(source) == "string"
  and source:gsub("^@", ""):match("^(.*)/lua/freeflow/daemon%.lua$")
if package_vendor then package_vendor = package_vendor .. "/vendor" end

function M.set_vendor_dir(dir)
  vendor_dir_override = dir
  vendor_version_cache = nil
  dependencies_ready = false
end

function M.vendor_dir()
  if vendor_dir_override ~= nil then
    return vendor_dir_override
  end
  if package_vendor then return package_vendor end
  -- Compiled chunks can omit source paths; managed state has the revision dir.
  if maki.pack and maki.pack.get then
    local packages = maki.pack.get()
    for _, package in ipairs(packages or {}) do
      local src = package.spec.src or ""
      if package.path and (package.spec.name == "maki-freeflow"
        or src:gsub("%.git$", ""):match("/maki%-freeflow/?$")) then
        return package.path .. "/vendor"
      end
    end
  end
  return config_dir() .. "/packages/maki-freeflow/vendor"
end

local function output_text(res, key)
  local value = res[key] or res[key .. "_lines"]
  if type(value) == "table" then return table.concat(value, "\n") end
  return type(value) == "string" and value or ""
end

function M.ensure_dependencies(rt)
  while dependencies_installing do maki.async.sleep(100) end
  if dependencies_ready then return true end
  dependencies_installing = true
  local id, err = maki.fn.jobstart({ rt.bin, M.vendor_dir() .. "/maki-setup.mjs" }, {
    on_stdout = function(_, line)
      if line:find("Installing FreeFlow", 1, true) then
        maki.log.info(line)
        maki.ui.flash(line)
      end
    end,
  })
  if not id then
    dependencies_installing = false
    return false, "freeflow: dependency setup spawn failed: " .. tostring(err)
  end
  local res = maki.fn.jobwait(id, 150000)
  dependencies_installing = false
  if not res then
    maki.fn.jobstop(id)
    return false, "freeflow: dependency setup timed out; run npm ci --omit=dev in " .. M.vendor_dir()
  end
  if res.exit_code ~= 0 then
    return false, "freeflow: dependency setup failed: " .. output_text(res, "stderr"):sub(-1500)
  end
  dependencies_ready = true
  return true
end

function M.daemon_entry()
  return M.vendor_dir() .. "/src/daemon.ts"
end

-- Daemon root (control plane + node-shim paths below join onto this:
-- /_health, /_client/*, /v1/models, /_shutdown).
function M.base_url()
  return "http://" .. M.HOST .. ":" .. tostring(M.PORT)
end

-- Provider API origin for maki.provider.register. Maki's codecs append
-- fixed paths to base_url ({base}/chat/completions for openai,
-- {base}/responses for openai-responses), and the daemon only serves API
-- routes under /v1/* — so this MUST carry the /v1 prefix. Registering the
-- bare root 404s every chat and responses request with {"error":"not found"}.
function M.api_base()
  return M.base_url() .. "/v1"
end

-- Vendored package.json version (what /_health must report). Cached.
function M.vendor_version()
  if vendor_version_cache == nil then
    vendor_version_cache = false -- negative cache: try once per load
    local text = maki.fs.read(M.vendor_dir() .. "/package.json")
    if text then
      local ok, parsed = pcall(maki.json.decode, text)
      if ok and type(parsed) == "table" and type(parsed.version) == "string" then
        vendor_version_cache = parsed.version
      end
    end
  end
  if vendor_version_cache == false then
    return nil
  end
  return vendor_version_cache
end

-- ── Lua-side HTTP via node one-shots (NOT maki.net.request) ──────────
-- Verified against maki-lua/src/api/net.rs (vet/validate_and_upgrade_url/
-- check_ssrf) and maki-providers/src/providers/plugin.rs (vouched_origin):
-- a user-config plugin registers with DeclAuthority::ThirdParty and a
-- plugin-declared base_url, so vouched_origin() is None and the
-- provider-origin exemption does NOT apply. maki.net.request would therefore
-- https-upgrade our http://127.0.0.1 URL and SSRF-block the loopback IP
-- unless the user adds net.allowed_private_hosts in maki.setup — a config
-- change outside this plugin's scope. Node (already required for the daemon)
-- fetches loopback plain-HTTP with no such restriction, so every Lua-side
-- daemon call rides a tiny `node -e` fetch shim. (Provider CHAT traffic is
-- unaffected: it flows through maki's Rust provider pipeline, not maki.net.)
--
-- Must run in a yieldable context (jobwait parks the task).

-- Raw HTTP: returns { status = n, body = s } or nil + err.
function M.http(method, path, body_text, timeout_ms)
  local rt, rt_err = M.node_runtime()
  if not rt then
    return nil, rt_err
  end
  local url_js = maki.json.encode(M.base_url() .. path)
  local opts_js
  if method == "GET" then
    opts_js = "{ method: \"GET\", signal: AbortSignal.timeout(" .. tostring(timeout_ms or 5000) .. ") }"
  else
    opts_js = "{ method: "
      .. maki.json.encode(method)
      .. ", headers: { \"content-type\": \"application/json\" }, body: "
      .. maki.json.encode(body_text or "")
      .. ", signal: AbortSignal.timeout("
      .. tostring(timeout_ms or 5000)
      .. ") }"
  end
  local js = "async function main() {\n"
    .. "const out = {};\ntry {\n"
    .. "const res = await fetch(" .. url_js .. ", " .. opts_js .. ");\n"
    .. "out.status = res.status;\ntry { out.body = await res.text(); } catch (e) { out.body = \"\"; }\n"
    .. "} catch (e) { out.error = String((e && e.message) || e); }\n"
    .. "console.log(JSON.stringify(out));\n}\nawait main();\n"
  local argv
  if rt.kind == "bun" then
    argv = { rt.bin, "-e", js }
  else
    argv = { rt.bin, "--input-type=module", "-e", js }
  end
  local id, start_err = maki.fn.jobstart(argv, {})
  if not id then
    return nil, "http shim spawn failed: " .. tostring(start_err)
  end
  local res = maki.fn.jobwait(id, 30000)
  if not res then
    return nil, "http shim timed out"
  end
  if res.exit_code ~= 0 then
    return nil, "http shim exited " .. tostring(res.exit_code)
  end
  local stdout = ""
  if type(res.stdout) == "string" then
    stdout = res.stdout
  elseif type(res.stdout) == "table" then
    stdout = table.concat(res.stdout, "\n")
  end
  local line = stdout:match("[^\n]*{.*}[^\n]*") or stdout
  local ok, parsed = pcall(maki.json.decode, line)
  if not ok or type(parsed) ~= "table" then
    return nil, "http shim returned bad JSON"
  end
  if parsed.error ~= nil then
    return nil, tostring(parsed.error)
  end
  return { status = parsed.status, body = parsed.body }, nil
end

-- GET path -> decoded JSON body, or nil + err string.
function M.get_json(path, timeout_secs)
  local res, err = M.http("GET", path, nil, (timeout_secs or 5) * 1000)
  if err then
    return nil, err
  end
  if res.status ~= 200 then
    return nil, "HTTP " .. tostring(res.status)
  end
  local ok, body = pcall(maki.json.decode, res.body)
  if not ok then
    return nil, "bad JSON from " .. path
  end
  return body, nil
end

-- True when GET /v1/models answers with JSON (mirror of isProxyAlive).
function M.probe_alive()
  local body, err = M.get_json("/v1/models", 5)
  return body ~= nil, err
end

function M.get_health()
  return M.get_json("/_health", 5)
end

function M.get_models()
  return M.get_json("/v1/models", 10)
end

-- POST /_client/{attach,heartbeat,detach} -> "ok" | "unknown" | "gone".
function M.control(endpoint, client_id)
  local res, err = M.http("POST", endpoint, maki.json.encode({ id = client_id }), 5000)
  if err then
    return "gone"
  end
  if res.status ~= 200 then
    return "gone"
  end
  local ok, parsed = pcall(maki.json.decode, res.body)
  if ok and type(parsed) == "table" and parsed.ok == false then
    return "unknown" -- daemon restarted since attach: re-attach
  end
  return "ok"
end

function M.attach(client_id)
  return M.control("/_client/attach", client_id)
end

-- Sync (no-yield) runtime presence check for the load-time gate.
-- Full `node --version` parsing happens lazily in node_runtime().
function M.runtimes_present()
  local node = maki.fn.executable("node") == 1
  local bun = maki.fn.executable("bun") == 1
  return node, bun
end

local runtime_cache = nil

-- Resolve { bin, kind } with kind "node"|"bun", or nil + loud error.
-- Node needs >=22.19 (the vendored engine requirement); Bun is also supported.
function M.node_runtime()
  if runtime_cache ~= nil then
    if runtime_cache == false then
      return nil, "freeflow: no node>=22 or bun on PATH — daemon cannot start"
    end
    return runtime_cache, nil
  end
  -- jobwait's stdout arrives as a string in some builds and a line list
  -- in others; accept string, stdout table, or stdout_lines table.
  local function stdout_text(res)
    if type(res.stdout) == "string" then
      return res.stdout
    end
    if type(res.stdout) == "table" then
      return table.concat(res.stdout, "\n")
    end
    if type(res.stdout_lines) == "table" then
      return table.concat(res.stdout_lines, "\n")
    end
    return ""
  end
  local function try_bin(bin, kind)
    -- No stdout/stderr redirect: the default tail capture is what jobwait
    -- reads back (stdout = false would discard the version string).
    local id = maki.fn.jobstart({ bin, "--version" }, {})
    if not id then
      return nil
    end
    local res = maki.fn.jobwait(id, 10000)
    if not res or res.exit_code ~= 0 then
      return nil
    end
    local out = stdout_text(res)
    local version = out:match("v?(%d+%.%d+%.?%d*)") or ""
    local major = tonumber(version:match("^(%d+)")) or 0
    local minor = tonumber(version:match("^%d+%.(%d+)")) or 0
    if kind == "node" and (major < 22 or (major == 22 and minor < 19)) then
      return nil, "node " .. version .. " too old"
    end
    return { bin = bin, kind = kind, version = version }, nil
  end
  local node_ok = maki.fn.executable("node") == 1
  local bun_ok = maki.fn.executable("bun") == 1
  if node_ok then
    local rt, note = try_bin("node", "node")
    if rt then
      runtime_cache = rt
      return rt, nil
    elseif note then
      maki.log.warn("freeflow: " .. note .. ", trying bun")
    end
  end
  if bun_ok then
    local rt = try_bin("bun", "bun")
    if rt then
      runtime_cache = rt
      return rt, nil
    end
  end
  runtime_cache = false
  return nil, "freeflow: no node>=22 or bun on PATH — install node 22+ to run the vendored daemon"
end

function M.spawn_argv(rt)
  if rt.kind == "bun" then
    return { rt.bin, M.daemon_entry() }
  end
  return { rt.bin, "--experimental-strip-types", M.daemon_entry() }
end

local stale_warned = false

local function check_version(health)
  local expected = M.vendor_version()
  if expected == nil or type(health) ~= "table" or health.version == nil then
    return
  end
  if health.version ~= expected and not stale_warned then
    stale_warned = true
    local msg = "freeflow: stale daemon v"
      .. tostring(health.version)
      .. " (plugin vendors v"
      .. tostring(expected)
      .. ") — run /freeflow kill, then /freeflow status to replace it"
    maki.log.warn(msg)
    maki.ui.flash(msg)
  end
end

-- Wait (up to timeout_ms) for GET /v1/models to answer.
local function wait_ready(timeout_ms)
  local waited = 0
  while waited < timeout_ms do
    local alive = M.probe_alive()
    if alive then
      return true
    end
    maki.async.sleep(200)
    waited = waited + 200
  end
  return M.probe_alive()
end

-- Ensure a daemon answers on :28180 and hold a lease for client_id.
-- Returns true + health-ish info on success, false + proxy-down message.
function M.ensure(client_id)
  local rt, rt_err = M.node_runtime()
  if not rt then return false, rt_err end
  local ready, setup_err = M.ensure_dependencies(rt)
  if not ready then return false, setup_err end
  local alive = M.probe_alive()
  if alive then
    M.attach(client_id)
    local health = M.get_health()
    if health then
      check_version(health)
    end
    return true, nil
  end
  -- Cold-start race guard (mirror client.ts jitter + re-probe): a sibling
  -- maki may be spawning right now.
  maki.async.sleep(100 + math.floor(math.random() * 200))
  if M.probe_alive() then
    M.attach(client_id)
    return true, nil
  end
  local id = maki.fn.jobfind(M.JOB_NAME)
  if not id then
    local spawn_id, spawn_err = maki.fn.jobstart(M.spawn_argv(rt), {
      name = M.JOB_NAME,
      scope = "plugin",
      stdout = false,
    })
    if not spawn_id then
      -- A live name under a dying job, or a real spawn failure: re-probe
      -- before giving up (another process may have won the race).
      maki.log.warn("freeflow: daemon spawn failed: " .. tostring(spawn_err))
    else
      id = spawn_id
      maki.log.info("freeflow: spawning daemon (" .. rt.kind .. " " .. tostring(rt.version or "?") .. ")")
    end
  end
  if wait_ready(5000) then
    M.attach(client_id)
    local health = M.get_health()
    if health then
      check_version(health)
    end
    return true, nil
  end
  local mapping = require("freeflow.mapping")
  if id then
    local res = maki.fn.jobwait(id, 1)
    if res and res.exit_code ~= 0 then
      return false, "freeflow: daemon exited " .. tostring(res.exit_code) .. ": " .. output_text(res, "stderr"):sub(-1500)
    end
  end
  return false, mapping.proxy_down_message(M.PORT)
end

function M.new_client_id()
  return string.format("maki-%d-%06d", os.time(), math.floor(math.random() * 1000000))
end

-- Heartbeat loop: attach/heartbeat the lease, re-attach when the daemon
-- restarted under us, respawn when it is gone. Runs forever in a spawn task;
-- /reload ends the task and the next load starts a fresh one.
function M.beat_forever()
  local client_id = M.new_client_id()
  local last_error
  local function ensure()
    local ok, err = M.ensure(client_id)
    if not ok and err ~= last_error then
      maki.log.error(err)
      maki.ui.flash(err)
    end
    last_error = ok and nil or err
  end
  ensure()
  while true do
    maki.async.sleep(M.HEARTBEAT_MS)
    local state = M.control("/_client/heartbeat", client_id)
    if state == "unknown" then
      M.attach(client_id)
    elseif state == "gone" then
      ensure()
    end
  end
end

return M
