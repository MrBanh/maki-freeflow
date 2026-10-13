package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local messages, windows, events = {}, {}, {}
local encoded = {}
local function encode(value)
  local key = "json-" .. tostring(#encoded + 1)
  encoded[#encoded + 1] = value
  encoded[key] = value
  return key
end
local job_result = { exit_code = 0, stdout = "result" }
local stopped = false
local job_opts
maki = {
  json = { encode = encode, decode = function(text) return assert(encoded[text]) end },
  ui = {
    flash = function(msg) messages[#messages + 1] = msg end,
    buf = function()
      local b = { lines = {} }
      function b:set_lines(lines) self.lines = lines; self.snapshots[#self.snapshots + 1] = table.concat(lines, "\n") end
      function b:line(line) self.lines[#self.lines + 1] = line end
      b.snapshots = {}
      return b
    end,
    open_win = function(buf, opts)
      local win = { buf = buf, opts = opts, events = table.remove(events, 1) or {} }
      function win:recv() return table.remove(self.events, 1) end
      function win:close() self.closed = true end
      windows[#windows + 1] = win
      return win
    end,
  },
  fn = {
    jobstart = function(argv, opts)
      job_opts = opts
      assert(not table.concat(argv, " "):find("test%-token"))
      assert(encoded[opts.env.MAKI_FREEFLOW_DEPLOY].token == "test-token")
      if opts.on_stdout then opts.on_stdout(1, "progress"); opts.on_stdout(1, "result") end
      return 1
    end,
    jobwait = function() return job_result, "timeout" end,
    jobstop = function() stopped = true end,
  },
}
package.loaded["freeflow.daemon"] = {
  node_runtime = function() return { kind = "node", bin = "node" } end,
  ensure_dependencies = function() return true end,
  vendor_dir = function() return "vendor" end,
}
encoded.progress = { type = "progress", message = "Uploading" }
encoded.result = { type = "result", ok = true, url = "https://relay.example", poolSaved = true, probe = { ok = true, status = 200, latencyMs = 1 } }
local deploy = require("freeflow.deploy")
local progress = {}
assert(deploy.run("cloudflare", "test-token", "relay", function(msg) progress[#progress + 1] = msg end).poolSaved)
assert(progress[1] == "Uploading")
assert(job_opts.stderr == false)
job_result = nil
local result, err = deploy.run("deno", "test-token", "relay", function() end)
assert(result == nil and err:find("timed out") and stopped)
job_result = { exit_code = 0, stdout_lines = { "result" } }

-- Test masked paste/edit input and platform picker using real dispatch UI logic.
events = {
  { { key = "<CR>" } },
  { { type = "paste", text = "test-tokenX\n" }, { key = "<BS>" }, { key = "<CR>" } },
  { { key = "<CR>" } },
}
deploy.dispatch("")
assert(messages[#messages]:find("Deployed & active"))
for _, snapshot in ipairs(windows[2].buf.snapshots) do assert(not snapshot:find("test%-token")) end
for _, win in ipairs(windows) do assert(win.closed) end
local before = #windows
deploy.dispatch("unknown")
assert(#windows == before and messages[#messages]:find("Usage"))
events = { { { key = "<Esc>" } } }
deploy.dispatch("vercel")
assert(messages[#messages]:find("cancelled"))

-- Export now strips the deployment's stored shared secret by default.
local state
local written
package.loaded["freeflow.relay"] = { state_file = function() return "state.json" end }
maki.fs = {
  read = function() return "state" end,
  write = function(_, text) written = encoded[text]; return true end,
}
local command = require("freeflow.command")
state = { relays = { { url = "https://relay.example", auth = "relay-secret" } } }
encoded.state = state
command.dispatch("export")
assert(written.relays[1].auth == nil)
encoded.state = { relays = { { url = "https://relay.example", auth = "relay-secret" } } }
command.dispatch("export --include-secrets")
assert(written.relays[1].auth == "relay-secret")

-- Informational popups must consume events and close explicitly.
local daemon = package.loaded["freeflow.daemon"]
daemon.ensure = function() return true end
daemon.new_client_id = function() return "test-client" end
daemon.get_health = function() return {} end
daemon.get_models = function() return { data = {} } end
daemon.vendor_version = function() return "test" end
daemon.PORT = 28180
local relay = package.loaded["freeflow.relay"]
relay.read_state = function() return { mode = "auto", url = "https://relay.example", relays = { { url = "https://relay.example" } } } end
relay.short_label = function() return "relay" end
for _, sub in ipairs({ "status", "list", "models" }) do
  for _, key in ipairs({ "<Esc>", "q", "<CR>" }) do
    events = { { { type = "resize" }, { type = "key", key = "x" }, { type = "key", key = key } } }
    command.dispatch(sub)
    local win = windows[#windows]
    assert(win.closed, sub .. " popup did not close on " .. key)
    assert(#win.events == 0, sub .. " popup did not process its close key")
    assert(win.opts.footer[1][2] == "close")
  end
end
print("deploy Lua checks passed")
