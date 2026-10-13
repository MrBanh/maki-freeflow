-- Interactive deployment using the upstream Node deployers and Maki window events.
local M = {}

local PLATFORMS = {
  { id = "cloudflare", label = "Cloudflare (recommended)", hint = "dash.cloudflare.com → API Tokens: Account Read + Workers Scripts Edit" },
  { id = "deno", label = "Deno Deploy", hint = "dash.deno.com → organization Access Tokens" },
  { id = "vercel", label = "Vercel", hint = "vercel.com/account/tokens" },
}

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function window(title, height)
  local buf = maki.ui.buf({ scratch = true })
  local win = maki.ui.open_win(buf, {
    title = " " .. title .. " ", width = "75%", height = height,
    needs_input = true, footer = { { "Enter", "accept" }, { "Esc", "cancel" } },
  })
  return buf, win
end

local function select_platform()
  local buf, win = window("Deploy relay on", 7)
  local selected = 1
  while true do
    local lines = {}
    for i, platform in ipairs(PLATFORMS) do
      lines[i] = (i == selected and "> " or "  ") .. platform.label
    end
    buf:set_lines(lines)
    local ev = win:recv()
    if not ev or ev.type == "close" or ev.key == "<Esc>" then break end
    if ev.key == "<CR>" then
      win:close()
      return PLATFORMS[selected]
    elseif ev.key == "<Down>" or ev.key == "j" then
      selected = selected % #PLATFORMS + 1
    elseif ev.key == "<Up>" or ev.key == "k" then
      selected = (selected - 2) % #PLATFORMS + 1
    end
  end
  win:close()
end

-- Dedicated masked input keeps API tokens out of chat/command history.
local function prompt(title, initial, secret, hint)
  local buf, win = window(title, 6)
  local text = initial or ""
  while true do
    buf:set_lines({ hint or "", "", secret and string.rep("*", #text) or text })
    local ev = win:recv()
    if not ev or ev.type == "close" or ev.key == "<Esc>" then break end
    if ev.key == "<CR>" then
      win:close()
      return trim(text)
    elseif ev.type == "paste" then
      text = text .. (ev.text or ""):gsub("[%c]", "")
    elseif ev.key == "<BS>" then
      text = text:gsub("[\1-\127\194-\244][\128-\191]*$", "")
    elseif ev.key == "<C-u>" then
      text = ""
    elseif ev.type == "key" then
      local key = ev.key or ""
      if key == "<Space>" then key = " " end
      if key == "<lt>" then key = "<" end
      if #key == 1 or (not key:match("^<") and #key > 0) then text = text .. key end
    end
  end
  win:close()
end

local function stdout_text(res)
  if type(res.stdout) == "string" then return res.stdout end
  return table.concat(res.stdout or res.stdout_lines or {}, "\n")
end

function M.run(platform, token, name, progress)
  local daemon = require("freeflow.daemon")
  local rt, err = daemon.node_runtime()
  if not rt then return nil, err end
  local ready, setup_err = daemon.ensure_dependencies(rt)
  if not ready then return nil, setup_err end
  local argv = { rt.bin }
  if rt.kind ~= "bun" then table.insert(argv, "--experimental-strip-types") end
  table.insert(argv, daemon.vendor_dir() .. "/maki-deploy.mjs")
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
    env = { MAKI_FREEFLOW_DEPLOY = maki.json.encode({ platform = platform, token = token, name = name }) },
    on_stdout = receive,
    stderr = false,
  })
  if not id then return nil, "deploy spawn failed: " .. tostring(start_err) end
  -- Platform build polling (120s), six probes (40s), and API upload time.
  local res, wait_err = maki.fn.jobwait(id, 300000)
  if not res then
    maki.fn.jobstop(id)
    return nil, "deploy timed out: " .. tostring(wait_err)
  end
  if not result then
    for line in stdout_text(res):gmatch("[^\n]+") do receive(id, line) end
  end
  if not result then return nil, "deploy exited " .. tostring(res.exit_code) .. " without a result" end
  if result.ok ~= true then return nil, tostring(result.error or "deployment failed") end
  return result
end

function M.dispatch(rest)
  local raw_platform, name = rest:match("^(%S+)%s*(.-)$")
  local platform
  if not raw_platform then
    platform = select_platform()
    if not platform then return end
  else
    raw_platform = raw_platform:lower()
    if raw_platform == "cf" then raw_platform = "cloudflare" end
    for _, p in ipairs(PLATFORMS) do if p.id == raw_platform then platform = p end end
    if not platform then
      maki.ui.flash("Usage: /freeflow deploy [cloudflare|cf|deno|vercel] [project-name]")
      return
    end
  end
  local token = prompt(platform.label .. " API token", "", true, platform.hint)
  if not token or token == "" then maki.ui.flash("Deploy cancelled: no token"); return end
  if not name or name == "" then
    name = prompt("Project name", "relay-" .. tostring(os.time()), false, "Enter to accept; Ctrl-U to clear")
    if not name then maki.ui.flash("Deploy cancelled"); return end
    if name == "" then name = "relay-" .. tostring(os.time()) end
  end
  local buf = maki.ui.buf({ scratch = true })
  local win = maki.ui.open_win(buf, { title = " Deploy " .. platform.label .. " relay ", width = "75%", height = 10, focus = false })
  local ok, result, err = pcall(M.run, platform.id, token, name, function(message) buf:line(message) end)
  token = nil
  if not ok then err, result = "deploy job failed", nil end
  local message
  if not result then
    message = "Deploy failed: " .. tostring(err)
  else
    local probe = result.probe or {}
    local note = probe.ok and (" — reachable (HTTP " .. tostring(probe.status) .. ", " .. tostring(probe.latencyMs) .. "ms)")
      or (" — deployed but unreachable (" .. tostring(probe.error or ("HTTP " .. tostring(probe.status))) .. "); retry /freeflow test " .. result.url)
    message = (result.poolSaved and "Deployed & active: " or "Relay live but NOT saved; redeploy after fixing state-file writes: ") .. result.url .. note
  end
  buf:line(message)
  win:close()
  maki.ui.flash(message)
end

return M
