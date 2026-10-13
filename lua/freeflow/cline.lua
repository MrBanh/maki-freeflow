-- /freeflow cline: Cline pool login for the maki port.
--
-- Ports pi-freeflow's `cline login/accounts/logout/signout` (src/commands.ts)
-- onto the same child-job pattern as freeflow/deploy.lua: a `node` one-shot
-- runs vendor/maki-cline.mjs, which imports cline-device-auth.ts (WorkOS
-- device flow) and cline-accounts.ts (0600 pool file) verbatim and streams
-- JSON progress/result events. Secrets ride the child environment, never
-- argv, temp files, or job output. Pool writes land beside the relay state
-- file, which the running daemon re-reads on mtime — no restart needed.
--
-- Deliberate differences from upstream (documented):
--   * login --key with no slot saves to the next free slot (default,
--     slot-2, …) instead of prompting for one.
--   * logout with no slot removes the only login, or asks for an explicit
--     slot when several are saved (no select menu in maki).
--   * The device-flow wait parks on jobwait (up to LOGIN_TIMEOUT_MS); closing
--     the progress window does not cancel it — the login finishes on its own
--     or expires, like upstream's fire-and-poll notify loop.
local M = {}

local input = require("freeflow.input")

-- Device codes live ~5 min upstream (expiresIn, default 300s); 11 min covers
-- 10-min codes with margin. Fast ops (accounts/logout/signout/save-key)
-- answer from disk or in one round trip.
local LOGIN_TIMEOUT_MS = 660000
local FAST_TIMEOUT_MS = 30000

local USAGE = "Usage: /freeflow cline login [--key] [slot] | /freeflow cline accounts | /freeflow cline logout [slot] | /freeflow cline signout"

local function stdout_text(res)
  if type(res.stdout) == "string" then return res.stdout end
  return table.concat(res.stdout or res.stdout_lines or {}, "\n")
end

-- Run the vendored cline adapter as a child job. request = { op, slot };
-- the token (save-key only) travels inside the SAME env payload, mirroring
-- deploy.run's MAKI_FREEFLOW_DEPLOY envelope. progress(line) streams child
-- progress events. Returns decoded result or nil + err.
function M.run(request, timeout_ms, progress)
  local daemon = require("freeflow.daemon")
  local rt, rt_err = daemon.node_runtime()
  if not rt then return nil, rt_err end
  local ready, setup_err = daemon.ensure_dependencies(rt)
  if not ready then return nil, setup_err end
  local argv = { rt.bin }
  if rt.kind ~= "bun" then table.insert(argv, "--experimental-strip-types") end
  table.insert(argv, daemon.vendor_dir() .. "/maki-cline.mjs")
  local result
  local function receive(_, line)
    local ok, event = pcall(maki.json.decode, line)
    if not ok or type(event) ~= "table" then return end
    if event.type == "progress" then
      progress(event.message)
    elseif event.type == "result" then
      result = event
    end
  end
  local id, start_err = maki.fn.jobstart(argv, {
    env = { MAKI_FREEFLOW_CLINE = maki.json.encode(request) },
    on_stdout = receive,
    stderr = false,
  })
  if not id then return nil, "cline spawn failed: " .. tostring(start_err) end
  local res, wait_err = maki.fn.jobwait(id, timeout_ms)
  if not res then
    maki.fn.jobstop(id)
    return nil, "cline timed out: " .. tostring(wait_err)
  end
  if not result then
    for line in stdout_text(res):gmatch("[^\n]+") do receive(id, line) end
  end
  if not result then return nil, "cline exited " .. tostring(res.exit_code) .. " without a result" end
  if result.ok ~= true then return nil, tostring(result.error or "cline failed") end
  return result
end

local function progress_window(title)
  local buf = maki.ui.buf({ scratch = true })
  local win = maki.ui.open_win(buf, { title = title, width = "75%", height = 12, focus = false })
  return buf, win
end

local function progress_lines(buf)
  return function(message)
    for line in tostring(message or ""):gmatch("[^\n]+") do buf:line(line) end
  end
end

-- Device login: approve in the browser, no paste. Shows the link + user code
-- in a progress window while the child polls WorkOS to expiry.
local function login_device(slot)
  local buf, win = progress_window(" Cline login ")
  local show = progress_lines(buf)
  show("Starting Cline login" .. (slot ~= "" and (" [" .. slot .. "]") or "") .. " …")
  local ok, result, err = pcall(M.run, { op = "login", slot = slot }, LOGIN_TIMEOUT_MS, show)
  if not ok then err, result = "cline job failed", nil end
  if not result then
    show("Login failed: " .. tostring(err))
  else
    show(result.message)
    if type(result.lines) == "table" then
      show("Cline logins (" .. tostring(result.count or #result.lines) .. "):")
      for _, line in ipairs(result.lines) do show(line) end
    end
  end
  win:close()
  if result then
    maki.ui.flash(result.message)
  else
    maki.ui.flash("Cline login failed: " .. tostring(err))
  end
end

-- Manual fallback: paste a workos: grant or clp_ key (masked, never shown
-- back). Empty slot saves to the next free slot instead of prompting.
local function login_key(slot)
  local key = input.prompt(
    "Cline API key" .. (slot ~= "" and (" for slot [" .. slot .. "]") or ""),
    "", true,
    "Paste workos: key or clp_ key — Enter to save, Esc to cancel")
  if not key or key == "" then maki.ui.flash("Cancelled — no API key provided"); return end
  local result, err = M.run({ op = "save-key", slot = slot, token = key }, FAST_TIMEOUT_MS, function() end)
  key = nil
  if not result then
    maki.ui.flash("Cline login failed: " .. tostring(err))
    return
  end
  maki.ui.flash(result.message)
end

local function show_accounts()
  local result, err = M.run({ op = "accounts" }, FAST_TIMEOUT_MS, function() end)
  if not result then
    maki.ui.flash("Cline accounts failed: " .. tostring(err))
    return
  end
  if (result.count or 0) == 0 then
    maki.ui.flash("No Cline logins saved — add one with /freeflow cline login")
    return
  end
  local lines = { "Cline logins (" .. tostring(result.count) .. "):" }
  for _, line in ipairs(result.lines or {}) do lines[#lines + 1] = line end
  maki.ui.flash(table.concat(lines, "\n"))
end

local function logout(slot)
  local result, err = M.run({ op = "logout", slot = slot }, FAST_TIMEOUT_MS, function() end)
  if not result then
    maki.ui.flash("Cline logout failed: " .. tostring(err))
    return
  end
  maki.ui.flash("Removed Cline login [" .. tostring(result.removed) .. "]"
    .. " (" .. tostring(result.count or 0) .. " login(s) left)")
end

local function signout()
  local result, err = M.run({ op = "signout" }, FAST_TIMEOUT_MS, function() end)
  if not result then
    maki.ui.flash("Cline signout failed: " .. tostring(err))
    return
  end
  maki.ui.flash(tostring(result.message or ""))
end

function M.dispatch(rest)
  local words = {}
  for w in (rest or ""):gmatch("%S+") do words[#words + 1] = w end
  local action = (words[1] or "accounts"):lower()
  if action == "login" then
    local paste = false
    local slot_parts = {}
    for i = 2, #words do
      if words[i] == "--key" then
        paste = true
      else
        slot_parts[#slot_parts + 1] = words[i]
      end
    end
    local slot = table.concat(slot_parts, " ")
    if paste then
      login_key(slot)
    else
      login_device(slot)
    end
  elseif action == "accounts" or action == "list" then
    show_accounts()
  elseif action == "logout" or action == "remove" then
    local slot_parts = {}
    for i = 2, #words do slot_parts[#slot_parts + 1] = words[i] end
    logout(table.concat(slot_parts, " "))
  elseif action == "signout" or action == "sign-out" or action == "switch" then
    signout()
  else
    maki.ui.flash(USAGE)
  end
end

return M
