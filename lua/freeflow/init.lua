-- freeflow: MVP port of pi-freeflow (https://github.com/trefeon/pi-freeflow)
-- to maki as a Lua plugin. Architecture: keep-Node-daemon + thin Lua plugin.
--
--   * The daemon (vendored VERBATIM under vendor/src/*.ts + vendor/package.json,
--     plus node_modules/undici for relay.ts's static `import { Agent }`) owns
--     port 127.0.0.1:28180 and all routing/upstream logic. Lua never edits it.
--   * Lua owns: daemon lifecycle (probe/attach/heartbeat/respawn, never kill),
--     two provider registrations sharing that one daemon, and the /freeflow
--     command. Relay mutations run as `node -e` one-shots importing the
--     vendored modules, so validation/locking stay upstream logic (see
--     relay.lua for the spike finding that makes this live with no restart).
--
-- Loaded as the maki-freeflow package: the maki.pack.add custom loader calls
-- require("freeflow").setup({ vendor_dir = package.path .. "/vendor" }).
-- setup() takes no other options today; vendor_dir is the only input.
local chat_rows = require("freeflow.models_chat")
local resp_rows = require("freeflow.models_responses")
local mapping = require("freeflow.mapping")
local daemon = require("freeflow.daemon")

local M = {}

local function static_auth()
  return function()
    return { headers = { Authorization = "Bearer public" } }
  end
end

local function make_list_models(rows)
  local index = mapping.index_rows(rows)
  local fallback = mapping.static_list_rows(rows)
  return function(ctx)
    -- ctx.get_json uses the provider origin + headers, so this follows a
    -- user who repoints the slug at a gateway.
    local body, err = ctx.get_json("/v1/models")
    if err then
      -- Daemon down: serve the static catalog so the picker is populated
      -- pre-daemon (mirrors pi's zero-latency static registration).
      return fallback
    end
    local mapped = mapping.map_daemon_models(body, index)
    if #mapped == 0 then
      return fallback
    end
    return mapped
  end
end

local function make_map_error(port)
  return function(_, status, message)
    return mapping.map_error(port, status, message)
  end
end

function M.setup(opts)
  if type(opts) == "table" and type(opts.vendor_dir) == "string" then
    daemon.set_vendor_dir(opts.vendor_dir)
  end

  -- ── Runtime gate (sync part) ────────────────────────────────────
  -- Full `node --version` parsing is lazy (needs jobwait, i.e. an async
  -- context) in daemon.node_runtime(); here we only fail loud and early when
  -- neither runtime exists at all.
  do
    local node_ok, bun_ok = daemon.runtimes_present()
    if not node_ok and not bun_ok then
      local msg = "freeflow: no node or bun on PATH — install node>=22 to run the vendored daemon"
      maki.log.error(msg)
      pcall(maki.ui.flash, msg)
    end
  end

  local port = daemon.PORT
  local base_url = daemon.base_url()

  -- ── Provider 1: freeflow (chat completions) ─────────────────────
  maki.provider.register({
    slug = "freeflow",
    display_name = "FreeFlow",
    codec = "openai",
    base_url = base_url,
    family = "generic",
    models = chat_rows,
    auth = static_auth(),
    list_models = make_list_models(chat_rows),
    map_error = make_map_error(port),
  })

  -- ── Provider 2: freeflow-responses (responses API, Zen rows) ────
  -- Disjoint from freeflow: these models HARD-require /v1/responses.
  maki.provider.register({
    slug = "freeflow-responses",
    display_name = "FreeFlow Responses",
    codec = "openai-responses",
    base_url = base_url,
    family = "generic",
    models = resp_rows,
    auth = static_auth(),
    list_models = make_list_models(resp_rows),
    map_error = make_map_error(port),
    -- Effort rides as body.reasoning.effort; the daemon clamps unsupported
    -- levels per model in normalizeResponsesBody. opts.thinking is nil when
    -- thinking is off, so nothing is sent then.
    build_body = function(_, body, _, opts)
      if opts and opts.thinking then
        body.reasoning = { effort = opts.thinking }
      end
      return body
    end,
  })

  -- ── /freeflow command ───────────────────────────────────────────
  require("freeflow.command").register()

  -- ── Heartbeat: hold our lease, re-attach/respawn when it drops ──
  -- spawn tasks end on plugin unload (/reload); the next load starts fresh,
  -- and every command lazily ensures, so a reload gap self-heals on next use.
  maki.async.spawn(daemon.beat_forever)

  return M
end

return M
