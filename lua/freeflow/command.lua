-- /freeflow slash command.
--
-- KEPT: status, list, models, auto, spread, on, off, add <URL> [name],
--   use <target> [new-label], label|rename <target> <name>, remove <target>,
--   kill, refresh, debug on|off, export/import, deploy, test, url.
-- CUT (with reasons, flashed when invoked):
--   export --dry-run .... dropped; import requires explicit --replace and
--   import --merge ...... has no merge mode (replace only).
--   logs ................ read the log file directly (path in status).
--   update .............. no host plugin manager for a vendored copy;
--                          update = re-copy src/ from a fresh clone.
--   hide/show/widget .... no status widget in maki.
--   install-startup ..... no startup-installer concept; daemon autostarts.
--   Interactive prompts . add/use/label/remove with no args print usage
--                          instead of opening input/select menus.
local M = {}

local CUT = {
  logs = "logs are cut — read the daemon log file directly (see /freeflow status for the state dir)",
  log = "logs are cut — read the daemon log file directly (see /freeflow status for the state dir)",
  trace = "trace is cut — read the daemon log file directly (see /freeflow status for the state dir)",
  update = "update is cut — update by re-copying src/*.ts from a fresh pi-freeflow clone",
  hide = "no status widget in maki — nothing to hide",
  show = "no status widget in maki — nothing to show",
  widget = "no status widget in maki",
  ["install-startup"] = "cut — the daemon autostarts on demand, no installer needed",
  ["uninstall-startup"] = "cut — nothing was installed",
}

local USAGE = "freeflow: status | list | models | auto | spread | on | off"
  .. " | add <URL> [name] | use <target> | label <target> <name>"
  .. " | remove <target> | kill | refresh | debug on|off"
  .. " | export [path] [--include-secrets] | import <path> --replace"
  .. " | deploy [cloudflare|deno|vercel] [name] | test [target] [--chat] | url [URL]"
  .. " | cline login [--key] [slot] | cline accounts | cline logout [slot] | cline signout"

local function flash(msg)
  maki.ui.flash(msg)
end

local function show_window(title, lines)
  local buf = maki.ui.buf({ scratch = true })
  for _, line in ipairs(lines) do
    buf:line(line)
  end
  local win = maki.ui.open_win(buf, {
    title = title, width = "70%", height = "60%",
    footer = { { "Esc / q / Enter", "close" } },
  })
  -- Focused plugin windows receive keys through recv(); the host does not
  -- supply a default dismissal handler for them.
  while true do
    local ev = win:recv()
    if not ev or ev.type == "close" then break end
    if ev.type == "key" and (ev.key == "<Esc>" or ev.key == "q" or ev.key == "<CR>") then break end
  end
  win:close()
end

local function split_first(args)
  local sub = args:match("^(%S+)") or ""
  local rest = args:sub(#sub + 1):gsub("^%s+", "")
  return sub:lower(), rest
end

local function split_words(rest)
  local words = {}
  for w in rest:gmatch("%S+") do
    table.insert(words, w)
  end
  return words
end

local MODE_LINES = {
  off = "Mode: off (always direct)",
  on = "Mode: on (always relay)",
  spread = "Mode: spread (rotates across healthy relays, auto-rolls on 429/5xx)",
  auto = "Mode: auto (enabled on session, auto-rolls on 429/5xx)",
}

local function do_status(daemon, relay)
  local ok, down_err = daemon.ensure(daemon.new_client_id())
  if not ok then
    flash(down_err)
    return
  end
  local health = daemon.get_health()
  local models = daemon.get_models()
  local state = relay.read_state()
  if not state then
    state = { mode = "auto", enabled = false, url = "", relays = {} }
  end
  local lines = {}
  local vendor = daemon.vendor_version() or "?"
  local dver = (type(health) == "table" and health.version) or "?"
  local catalog = 0
  if type(models) == "table" and type(models.data) == "table" then
    catalog = #models.data
  end
  local clients = (type(health) == "table" and health.clients) or 0
  table.insert(lines, "freeflow plugin v" .. vendor .. " — daemon v" .. dver .. " on 127.0.0.1:" .. tostring(daemon.PORT))
  table.insert(lines, MODE_LINES[state.mode] or ("Mode: " .. tostring(state.mode or "auto")))
  local relays = state.relays or {}
  local active = state.url or ""
  table.insert(lines, #relays .. " relay(s)" .. (#relays > 0 and (" | active: " .. relay.short_label(active, relays)) or " (direct mode)"))
  table.insert(lines, "State file: " .. relay.state_file())
  table.insert(lines, "Daemon catalog: " .. tostring(catalog) .. " models | clients: " .. tostring(clients))
  show_window(" freeflow status ", lines)
end

local function do_list(daemon, relay)
  local state = relay.read_state()
  if not state or #(state.relays or {}) == 0 then
    flash("No saved relays — add one with /freeflow add <URL>")
    return
  end
  local health = daemon.get_health()
  local health_by_url = {}
  if type(health) == "table" and type(health.relays) == "table" then
    for _, h in ipairs(health.relays) do
      if type(h.url) == "string" then
        health_by_url[h.url] = h
      end
    end
  end
  local lines = {}
  for i, r in ipairs(state.relays) do
    local star = (r.url == state.url) and "* " or "  "
    local label = (type(r.label) == "string" and r.label ~= "" and ("[" .. r.label .. "] ") or "")
    local h = health_by_url[r.url]
    local flag = ""
    if h ~= nil then
      flag = h.healthy and " (healthy)" or " (cooldown)"
    end
    table.insert(lines, star .. "[" .. tostring(i) .. "] " .. label .. r.url .. flag)
  end
  show_window(" freeflow relays (" .. tostring(#state.relays) .. ") ", lines)
end

local function do_models(daemon)
  local ok, down_err = daemon.ensure(daemon.new_client_id())
  if not ok then
    flash(down_err)
    return
  end
  local models = daemon.get_models()
  if type(models) ~= "table" or type(models.data) ~= "table" then
    flash("Could not read daemon catalog")
    return
  end
  local chat_rows = require("freeflow.models_chat")
  local resp_rows = require("freeflow.models_responses")
  local mapping = require("freeflow.mapping")
  local index = mapping.index_rows(chat_rows)
  for _, row in ipairs(resp_rows) do
    for _, prefix in ipairs(row.prefixes or {}) do
      if index[prefix] == nil then
        index[prefix] = row
      end
    end
  end
  local lines = {}
  for i, entry in ipairs(models.data) do
    local id = (type(entry) == "table" and entry.id) or tostring(entry)
    local row = index[id]
    local tier = (row and row.tier) or "?"
    table.insert(lines, "[" .. tostring(i) .. "] " .. id .. " [" .. tier .. "]")
  end
  show_window(" freeflow models (" .. tostring(#models.data) .. ") ", lines)
end

local function do_set_mode(relay, vendor_dir, mode)
  local js = "const next = relay.withRelayState((s) => { s.mode = "
    .. maki.json.encode(mode)
    .. "; s.enabled = (s.mode !== \"off\"); s.url = s.url || \"\";"
    .. " if (s.url) { relay.ensureRelay(s, s.url); } return s; });\n"
    .. "out.ok = true; out.state = { mode: next.mode, enabled: next.enabled, url: next.url, relays: next.relays };"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then
    flash("freeflow " .. mode .. " failed: " .. tostring(err))
    return
  end
  flash(relay.flash_summary(out.state))
end

local function do_add(relay, vendor_dir, rest)
  local words = split_words(rest)
  if #words == 0 then
    flash("Usage: /freeflow add <URL> [name]")
    return
  end
  local url_js = maki.json.encode(words[1])
  local label_js = (#words > 1) and maki.json.encode(table.concat(words, " ", 2)) or "undefined"
  local js = "const next = relay.withRelayState((s) => {"
    .. " const added = relay.ensureRelay(s, " .. url_js .. ", " .. label_js .. ");"
    .. " s.enabled = true; s.url = added.url; return s; });\n"
    .. "out.ok = true; out.state = { mode: next.mode, enabled: next.enabled, url: next.url, relays: next.relays };"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then
    flash("freeflow add failed: " .. tostring(err))
    return
  end
  local st = out.state or {}
  flash("Added & activated relay [" .. relay.short_label(st.url, st.relays) .. "]: " .. tostring(st.url or ""))
end

local function do_use(relay, vendor_dir, rest)
  local words = split_words(rest)
  if #words == 0 then
    flash("Usage: /freeflow use <URL|name|index>")
    return
  end
  local target_js = maki.json.encode(words[1])
  local label_js = (#words > 1) and maki.json.encode(table.concat(words, " ", 2)) or "undefined"
  -- Saved relay (by index/label/URL) wins; an absolute http(s) URL that is
  -- not saved yet is added on the fly (mirrors upstream `use`).
  local js = "const next = relay.withRelayState((s) => {"
    .. " const m = relay.findRelay(s, " .. target_js .. ");"
    .. " if (m) { s.enabled = true; s.url = m.url;"
    .. " if (" .. label_js .. " !== undefined) { m.label = " .. label_js .. "; } return s; }\n"
    .. " let u = null; try { u = new URL(" .. target_js .. "); } catch (e) {}\n"
    .. " if (u && (u.protocol === \"http:\" || u.protocol === \"https:\")) {"
    .. " const added = relay.ensureRelay(s, " .. target_js .. ", " .. label_js .. ");"
    .. " s.enabled = true; s.url = added.url; return s; }\n"
    .. " throw new Error(\"Relay '\" + " .. target_js .. " + \"' not found in saved list\"); });\n"
    .. "out.ok = true; out.state = { mode: next.mode, enabled: next.enabled, url: next.url, relays: next.relays };"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then
    flash("freeflow use failed: " .. tostring(err))
    return
  end
  flash(relay.flash_summary(out.state))
end

local function do_label(relay, vendor_dir, rest)
  local words = split_words(rest)
  if #words < 2 then
    flash("Usage: /freeflow label <URL|name|index> <name>")
    return
  end
  local target_js = maki.json.encode(words[1])
  local label_js = maki.json.encode(table.concat(words, " ", 2))
  local js = "const next = relay.withRelayState((s) => {"
    .. " const r = relay.setRelayLabel(s, " .. target_js .. ", " .. label_js .. ");"
    .. " if (!r) { throw new Error(\"Relay '\" + " .. target_js .. " + \"' not found in saved list\"); }"
    .. " return s; });\n"
    .. "out.ok = true; out.state = { mode: next.mode, enabled: next.enabled, url: next.url, relays: next.relays };"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then
    flash("freeflow label failed: " .. tostring(err))
    return
  end
  flash("Relay short name updated to [" .. table.concat(words, " ", 2) .. "]")
end

local function do_remove(relay, vendor_dir, rest)
  local words = split_words(rest)
  if #words == 0 then
    flash("Usage: /freeflow remove <URL|name|index>")
    return
  end
  local state = relay.read_state()
  if not state then
    flash("No saved relays")
    return
  end
  local matched = relay.find_relay(state, words[1])
  if not matched then
    flash("Relay '" .. words[1] .. "' not in saved list")
    return
  end
  if matched.url == state.url then
    flash("Cannot remove the active relay — switch to another relay first")
    return
  end
  local url_js = maki.json.encode(matched.url)
  local js = "const next = relay.withRelayState((s) => { relay.removeRelay(s, " .. url_js .. "); return s; });\n"
    .. "out.ok = true; out.state = { mode: next.mode, enabled: next.enabled, url: next.url, relays: next.relays };"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then
    flash("freeflow remove failed: " .. tostring(err))
    return
  end
  flash("Removed: " .. matched.url)
end

local function do_kill(daemon)
  -- Via the node-fetch shim (see daemon.lua): maki.net.request cannot reach
  -- loopback from a ThirdParty plugin without net.allowed_private_hosts.
  local res, err = daemon.http("POST", "/_shutdown", "", 5000)
  if err then
    flash("Daemon not running or not reachable")
    return
  end
  if res.status == 200 then
    flash("Proxy daemon stopped — next freeflow use restarts it")
  else
    flash("Daemon kill got HTTP " .. tostring(res.status))
  end
end

local function do_refresh(daemon)
  local ok, down_err = daemon.ensure(daemon.new_client_id())
  if not ok then
    flash(down_err)
    return
  end
  local models = daemon.get_models()
  local count = (type(models) == "table" and type(models.data) == "table") and #models.data or 0
  -- No host-side live-upstream refresh: the daemon owns its catalog and
  -- refreshes it in the background (seedCatalog). This re-probes it.
  flash("Daemon catalog: " .. tostring(count) .. " models (daemon refreshes live upstreams in the background)")
end

local function do_debug(relay, vendor_dir, rest)
  local arg = rest:lower()
  if arg == "on" or arg == "enable" or arg == "true" or arg == "off" or arg == "disable" or arg == "false" then
    local flag = (arg == "on" or arg == "enable" or arg == "true") and "true" or "false"
    local js = "logger.saveDebugState({ debug: " .. flag .. " });\n"
      .. "out.ok = true; out.state = logger.loadDebugState() || { debug: " .. flag .. " };"
    local out, err = relay.run_logger_shim(js, vendor_dir)
    if not out then
      flash("freeflow debug failed: " .. tostring(err))
      return
    end
    if flag == "true" then
      flash("Debug ON — verbose trace enabled (level=debug)")
    else
      flash("Debug OFF — level restored to info")
    end
    return
  end
  if arg == "" then
    local text = maki.fs.read(relay.debug_file())
    local cur = "info"
    if text then
      local ok, parsed = pcall(maki.json.decode, text)
      if ok and type(parsed) == "table" then
        cur = (parsed.debug and "debug (ON)") or parsed.level or "info"
      end
    end
    flash("Debug status: " .. cur .. " | File: " .. relay.debug_file())
    return
  end
  flash("Usage: /freeflow debug on|off")
end

local function do_export(relay, rest)
  local words = split_words(rest)
  local dest = "pi-freeflow-export.json"
  local include_secrets = false
  for _, word in ipairs(words) do
    if word == "--include-secrets" then
      include_secrets = true
    elseif word:match("^%-%-") then
      flash("Usage: /freeflow export [path] [--include-secrets]")
      return
    else
      dest = word
    end
  end
  local text, err = maki.fs.read(relay.state_file())
  if err then
    flash("Export failed: no state file yet (" .. tostring(err) .. ")")
    return
  end
  local valid, state = pcall(maki.json.decode, text)
  if not valid or type(state) ~= "table" then flash("Export failed: corrupt relay state"); return end
  if not include_secrets then
    for _, entry in ipairs(state.relays or {}) do entry.auth = nil end
  end
  text = maki.json.encode(state)
  local ok, werr = maki.fs.write(dest, text)
  if not ok then
    flash("Export failed: " .. tostring(werr))
    return
  end
  flash("Exported relay state to " .. dest .. (include_secrets and " (includes relay secrets)" or " (relay secrets stripped)"))
end

local function do_test(relay, vendor_dir, rest)
  local target = nil
  local chat = false
  for _, word in ipairs(split_words(rest)) do
    if word == "--chat" then chat = true
    elseif word:match("^%-%-") or target then
      flash("Usage: /freeflow test [URL|name|index|opencode] [--chat]")
      return
    else target = word end
  end
  local js = "const { probeRelay } = await import(VENDOR + '/src/probe.ts');"
    .. "const s = relay.loadRelayState(); const target = " .. maki.json.encode(target or "") .. ";"
    .. "const direct = target === 'opencode' || target === 'direct';"
    .. "const entry = relay.findRelay(s, target || s.url);"
    .. "const url = direct ? 'https://opencode.ai' : entry?.url || target || s.url;"
    .. "if (!url) throw new Error('No saved relays — deploy one with /freeflow deploy');"
    .. "out.probe = await probeRelay(url, entry?.auth, { endpoint: " .. maki.json.encode(chat and "chat" or "models") .. " });"
    .. "out.url = url; out.ok = true;"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then flash("Relay test failed: " .. tostring(err)); return end
  local probe = out.probe or {}
  flash(out.url .. (probe.ok and " reachable" or " unreachable") .. " (HTTP " .. tostring(probe.status)
    .. ", " .. tostring(probe.latencyMs) .. "ms)" .. (probe.error and (": " .. probe.error) or ""))
end

local function do_url(relay, vendor_dir, rest)
  if rest == "" then
    local state = relay.read_state() or {}
    flash("Active relay URL: " .. tostring(state.url or "") .. " | /freeflow url <URL> to set")
    return
  end
  local js = "const next = relay.withRelayState((s) => { const r = relay.ensureRelay(s, "
    .. maki.json.encode(rest) .. "); s.url = r.url; return s; }); out.ok = true; out.state = next;"
  local out, err = relay.run_shim(js, vendor_dir)
  if not out then flash("freeflow url failed: " .. tostring(err)); return end
  flash(relay.flash_summary(out.state))
end

local function do_import(relay, rest)
  local words = split_words(rest)
  if #words == 0 then
    flash("Usage: /freeflow import <path> --replace")
    return
  end
  local want_replace = false
  local path = nil
  for _, w in ipairs(words) do
    if w == "--replace" then
      want_replace = true
    elseif not path then
      path = w
    end
  end
  if not path or not want_replace then
    flash("Usage: /freeflow import <path> --replace (--replace is required; --merge/--dry-run are cut)")
    return
  end
  local text, rerr = maki.fs.read(path)
  if rerr then
    flash("Import failed: " .. tostring(rerr))
    return
  end
  local ok, parsed = pcall(maki.json.decode, text)
  if not ok or type(parsed) ~= "table" or type(parsed.relays) ~= "table" then
    flash("Import failed: not a relay-state file (missing relays array)")
    return
  end
  local wok, werr = maki.fs.atomic_write(relay.state_file(), text)
  if not wok then
    flash("Import failed: " .. tostring(werr))
    return
  end
  flash("Imported " .. tostring(#parsed.relays) .. " relay(s) (replaced)")
end

function M.dispatch(raw_args)
  local daemon = require("freeflow.daemon")
  local relay = require("freeflow.relay")
  local vendor_dir = daemon.vendor_dir()
  local sub, rest = split_first(raw_args or "")
  if sub == "" then
    flash(USAGE)
    return
  end
  if CUT[sub] then
    flash(CUT[sub])
    return
  end
  if sub == "status" then
    do_status(daemon, relay)
  elseif sub == "list" then
    do_list(daemon, relay)
  elseif sub == "models" then
    do_models(daemon)
  elseif sub == "auto" or sub == "spread" or sub == "on" or sub == "off" then
    do_set_mode(relay, vendor_dir, sub)
  elseif sub == "add" then
    do_add(relay, vendor_dir, rest)
  elseif sub == "use" then
    do_use(relay, vendor_dir, rest)
  elseif sub == "label" or sub == "rename" then
    do_label(relay, vendor_dir, rest)
  elseif sub == "remove" then
    do_remove(relay, vendor_dir, rest)
  elseif sub == "kill" or sub == "stop" or sub == "shutdown" then
    do_kill(daemon)
  elseif sub == "refresh" or sub == "reload" then
    do_refresh(daemon)
  elseif sub == "debug" then
    do_debug(relay, vendor_dir, rest)
  elseif sub == "export" then
    do_export(relay, rest)
  elseif sub == "import" then
    do_import(relay, rest)
  elseif sub == "deploy" then
    require("freeflow.deploy").dispatch(rest)
  elseif sub == "test" then
    do_test(relay, vendor_dir, rest)
  elseif sub == "url" then
    do_url(relay, vendor_dir, rest)
  elseif sub == "cline" then
    require("freeflow.cline").dispatch(rest)
  else
    flash("Unknown /freeflow subcommand '" .. sub .. "' — " .. USAGE)
  end
end

function M.register()
  maki.api.register_command({
    name = "/freeflow",
    description = "FreeFlow: local proxy for free models (status/list/models/use/...)",
    nargs = "*",
    handler = function(opts)
      maki.async.spawn(function()
        local ok, err = pcall(M.dispatch, (opts and opts.args) or "")
        if not ok then
          local msg = "freeflow error: " .. tostring(err)
          maki.log.error(msg)
          maki.ui.flash(msg)
        end
      end)
    end,
  })
end

return M
