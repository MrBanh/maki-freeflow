-- Relay-state access for the freeflow plugin.
--
-- SPIKE FINDING (verified live against the vendored daemon, see vendor/VENDORED.md):
-- relay-state.ts getActiveRelayState / getOrderedRelayUrls re-read the state
-- file whenever its mtime moves, and mutations go through CAS withRelayState
-- (freshest-disk-state + atomic tmp+rename + lock file). So an external
-- process writing the same state file takes effect on the running daemon
-- WITHOUT a restart — proven: a node one-shot added a relay, and the live
-- daemon's /_health reported it on the next request.
--
-- Design consequence: Lua-side use/add/remove do NOT need daemon RPC.
-- They run as tiny `node -e` one-shot shims that import the VENDORED
-- relay-state.ts / logger.ts verbatim (withRelayState, ensureRelay,
-- findRelay, setRelayLabel, removeRelay, saveDebugState), so validation,
-- locking and atomic writes stay upstream logic, not a Lua re-implementation.
-- Reads (status/list) parse the state file directly in Lua — no spawn cost.
local M = {}

function M.data_dir()
  local override = maki.uv.os_getenv("PI_FREEFLOW_DATA_DIR")
  if type(override) == "string" and override:match("%S") then
    return override
  end
  return maki.uv.os_homedir() .. "/.pi/agent"
end

function M.state_file()
  return M.data_dir() .. "/pi-freeflow-relay-state.json"
end

function M.debug_file()
  return M.data_dir() .. "/pi-freeflow-debug.json"
end

-- Read + decode the on-disk relay state. Returns table or nil + err.
-- Tolerates a missing file (fresh install, daemon never wrote one).
function M.read_state()
  local text, err = maki.fs.read(M.state_file())
  if err then
    return nil, err
  end
  local ok, parsed = pcall(maki.json.decode, text)
  if not ok or type(parsed) ~= "table" then
    return nil, "state file is corrupt"
  end
  return parsed, nil
end

-- Lua mirror of relay-state.ts findRelay (1-based index, exact URL,
-- case-insensitive label, partial URL). Used for read-side guards.
function M.find_relay(state, identifier)
  local relays = (type(state) == "table" and state.relays) or {}
  if type(identifier) == "number" then
    local idx = identifier == 0 and 1 or identifier
    return relays[idx]
  end
  local str = tostring(identifier or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if str == "" then
    return nil
  end
  if str:match("^%d+$") then
    local num = tonumber(str)
    if num and num >= 1 and num <= #relays then
      return relays[num]
    end
  end
  for _, r in ipairs(relays) do
    if r.url == str then
      return r
    end
  end
  local lower = str:lower()
  for _, r in ipairs(relays) do
    if type(r.label) == "string" and r.label:lower() == lower then
      return r
    end
  end
  for _, r in ipairs(relays) do
    if type(r.url) == "string" and r.url:lower():find(lower, 1, true) then
      return r
    end
  end
  return nil
end

-- Lua mirror of relay-state.ts shortRelayLabel.
function M.short_label(url, relays)
  for _, r in ipairs(relays or {}) do
    if r.url == url and type(r.label) == "string" and r.label:match("%S") and r.label ~= "manual" then
      return r.label
    end
  end
  local host = tostring(url or ""):match("^https?://([^/]+)") or ""
  host = host:gsub(":%d+$", "")
  if host:match("^(%d+%.%d+%.%d+%.%d+)$") then
    return host
  end
  local parts = {}
  for p in host:gmatch("[^.]+") do
    table.insert(parts, p)
  end
  if #parts >= 3 then
    return parts[1]
  end
  return parts[1] or tostring(url or ""):sub(1, 18)
end

-- Escape an absolute path for embedding in a JS double-quoted string.
local function js_string_path(path)
  return (tostring(path):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Run a JS snippet that may `await import(...)` vendored TS modules and must
-- assign `out` ({ ok = true/false, ... }). Returns decoded out or nil + err.
-- Must run in a yieldable context (jobwait parks the task).
function M.run_shim(body_js, vendor_dir)
  local daemon = require("freeflow.daemon")
  local rt, rt_err = daemon.node_runtime()
  if not rt then
    return nil, rt_err
  end
  local vendor_url = "file://" .. js_string_path(vendor_dir)
  local js = "const VENDOR = \""
    .. vendor_url
    .. "\";\nasync function main() {\n"
    .. "const relay = await import(VENDOR + \"/src/relay-state.ts\");\n"
    .. "const out = {};\ntry {\n"
    .. body_js
    .. "\n} catch (e) { out.ok = false; out.error = String((e && e.message) || e); }\n"
    .. "console.log(JSON.stringify(out));\n}\nawait main();\n"
  local argv
  if rt.kind == "bun" then
    argv = { rt.bin, "-e", js }
  else
    argv = { rt.bin, "--experimental-strip-types", "--input-type=module", "-e", js }
  end
  local id, start_err = maki.fn.jobstart(argv, {})
  if not id then
    return nil, "shim spawn failed: " .. tostring(start_err)
  end
  local res, wait_err = maki.fn.jobwait(id, 30000)
  if not res then
    return nil, "shim timed out: " .. tostring(wait_err)
  end
  if res.exit_code ~= 0 then
    local tail = ""
    if type(res.stderr) == "string" then
      tail = res.stderr:sub(-300)
    end
    return nil, "shim exited " .. tostring(res.exit_code) .. " " .. tail
  end
  local stdout = ""
  if type(res.stdout) == "string" then
    stdout = res.stdout
  end
  local line = stdout:match("[^\n]*{.*}[^\n]*") or stdout
  local ok, parsed = pcall(maki.json.decode, line)
  if not ok or type(parsed) ~= "table" then
    return nil, "shim returned bad JSON"
  end
  if parsed.ok ~= true then
    return nil, tostring(parsed.error or "relay mutation failed")
  end
  return parsed, nil
end

-- Like run_shim but imports logger.ts instead of relay-state.ts (debug file).
function M.run_logger_shim(body_js, vendor_dir)
  local daemon = require("freeflow.daemon")
  local rt, rt_err = daemon.node_runtime()
  if not rt then
    return nil, rt_err
  end
  local vendor_url = "file://" .. js_string_path(vendor_dir)
  local js = "const VENDOR = \""
    .. vendor_url
    .. "\";\nasync function main() {\n"
    .. "const logger = await import(VENDOR + \"/src/logger.ts\");\n"
    .. "const out = {};\ntry {\n"
    .. body_js
    .. "\n} catch (e) { out.ok = false; out.error = String((e && e.message) || e); }\n"
    .. "console.log(JSON.stringify(out));\n}\nawait main();\n"
  local argv
  if rt.kind == "bun" then
    argv = { rt.bin, "-e", js }
  else
    argv = { rt.bin, "--experimental-strip-types", "--input-type=module", "-e", js }
  end
  local id, start_err = maki.fn.jobstart(argv, {})
  if not id then
    return nil, "shim spawn failed: " .. tostring(start_err)
  end
  local res = maki.fn.jobwait(id, 30000)
  if not res then
    return nil, "shim timed out"
  end
  if res.exit_code ~= 0 then
    return nil, "shim exited " .. tostring(res.exit_code)
  end
  local stdout = type(res.stdout) == "string" and res.stdout or ""
  local line = stdout:match("[^\n]*{.*}[^\n]*") or stdout
  local ok, parsed = pcall(maki.json.decode, line)
  if not ok or type(parsed) ~= "table" then
    return nil, "shim returned bad JSON"
  end
  if parsed.ok ~= true then
    return nil, tostring(parsed.error or "debug update failed")
  end
  return parsed, nil
end

-- One-line flash summary mirroring formatRelayFlash (mode + pool + active).
function M.flash_summary(state)
  state = state or {}
  local relays = state.relays or {}
  local mode = state.mode or "auto"
  local active = state.url or ""
  local label = active ~= "" and M.short_label(active, relays) or "-"
  return "freeflow " .. mode .. " — " .. tostring(#relays) .. " relay(s), active: " .. label
end

return M
