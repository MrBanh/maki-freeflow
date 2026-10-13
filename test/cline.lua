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
local no_events = false
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
      job_opts = { argv = argv, opts = opts }
      local req = encoded[opts.env.MAKI_FREEFLOW_CLINE]
      if req.token then
        assert(req.token == "test-cline-key")
        assert(not table.concat(argv, " "):find("test%-cline%-key"), "secret leaked into argv")
      end
      if opts.on_stdout and not no_events then opts.on_stdout(1, "progress"); opts.on_stdout(1, "result") end
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
local prompted = {}
package.loaded["freeflow.input"] = {
  prompt = function(title, initial, secret, hint)
    prompted = { title = title, secret = secret, hint = hint }
    return table.remove(events, 1)
  end,
}
local cline = require("freeflow.cline")

-- run() envelope: secret in env (never argv), progress/result streaming.
encoded.progress = { type = "progress", message = "Open this link" }
encoded.result = { type = "result", ok = true, message = "Saved Cline login [default]", count = 1 }
local progress = {}
local result = assert(cline.run({ op = "save-key", slot = "s", token = "test-cline-key" }, 30000,
  function(msg) progress[#progress + 1] = msg end))
assert(result.count == 1 and progress[1] == "Open this link")
assert(job_opts.opts.stderr == false)
assert(job_opts.argv[#job_opts.argv] == "vendor/maki-cline.mjs")
job_result = nil
local _, err = cline.run({ op = "login" }, 30000, function() end)
assert(err:find("timed out") and stopped)
job_result = { exit_code = 3, stdout = "{}" }
encoded["{}"] = { note = "decodes, but carries no result event" }
no_events = true
local ok, jerr = pcall(maki.json.decode, "no json here")
assert(not ok and jerr)
result, err = cline.run({ op = "login" }, 30000, function() end)
assert(result == nil and err:find("without a result"))
job_result = { exit_code = 0, stdout_lines = { "result" } }

-- dispatch() routing with a stubbed runner (no child spawns from here on).
local ran = {}
cline.run = function(request, timeout, on_progress)
  ran = { request = request, timeout = timeout }
  if request.op == "login" then
    on_progress("Cline login [default]\nEnter code: ABCD-1234")
    return { message = "Saved Cline login [default]", count = 1, lines = { "  [1] [default] key ending …st-key" } }
  end
  if request.op == "save-key" then return { message = "Saved Cline login [slot-x]", count = 1 } end
  if request.op == "accounts" then return { count = 0, lines = {} } end
  if request.op == "logout" then return { removed = "default", count = 0 } end
  if request.op == "signout" then return { message = "Sign out in your browser:\nhttps://example.invalid/logout" } end
end

-- Device login streams link+code lines into a progress window, then flashes.
cline.dispatch("login")
assert(ran.request.op == "login" and ran.request.slot == "")
assert(ran.timeout == 660000)
local win = windows[#windows]
assert(win.closed and win.opts.focus == false)
assert(table.concat(win.buf.lines, "\n"):find("ABCD%-1234"))
assert(messages[#messages]:find("Saved Cline login"))

-- Explicit slot survives; --key uses the masked prompt and env secret.
events = { "test-cline-key" }
cline.dispatch("login work --key")
assert(ran.request.op == "save-key" and ran.request.slot == "work")
assert(ran.request.token == "test-cline-key" and prompted.secret == true)
assert(messages[#messages]:find("slot%-x"))
events = { nil }
cline.dispatch("login --key")
assert(messages[#messages]:find("Cancelled"))

-- accounts / logout / signout / usage.
cline.dispatch("")
assert(ran.request.op == "accounts")
assert(messages[#messages]:find("No Cline logins"))
cline.dispatch("logout")
assert(ran.request.op == "logout" and ran.request.slot == "")
assert(messages[#messages]:find("Removed Cline login"))
cline.dispatch("signout")
assert(messages[#messages]:find("Sign out in your browser"))
cline.dispatch("bogus-action")
assert(messages[#messages]:find("cline login"))

-- command.lua routes cline (no longer cut) through to the same dispatch.
package.loaded["freeflow.relay"] = {}
local command = require("freeflow.command")
cline.run = function() return { count = 0, lines = {} } end
command.dispatch("cline accounts")
assert(messages[#messages]:find("No Cline logins"), "cline must not hit the CUT table")

-- Real input.prompt masks secrets in window snapshots.
package.loaded["freeflow.input"] = nil
local real_input = loadfile("lua/freeflow/input.lua")()
assert(real_input.trim("  a b  ") == "a b")
events = { { { type = "paste", text = "s3cr3t\n" }, { key = "<CR>" } } }
assert(real_input.prompt("Key", "", true, "hint") == "s3cr3t")
local pwin = windows[#windows]
assert(pwin.closed)
for _, snapshot in ipairs(pwin.buf.snapshots) do assert(not snapshot:find("s3cr3t")) end
events = { { { key = "<Esc>" } } }
assert(real_input.prompt("Key", "", true, "hint") == nil)
print("cline Lua checks passed")
