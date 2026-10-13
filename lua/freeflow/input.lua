-- Shared prompt windows for freeflow commands.
--
-- Secrets typed here never enter chat or command history: the window feeds
-- keys directly from win:recv(), and callers pass the result to the child
-- environment (never argv or job output). Split out for freeflow/cline.lua;
-- freeflow/deploy.lua keeps its own local copy (untouched, still tested).
local M = {}

function M.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.window(title, height)
  local buf = maki.ui.buf({ scratch = true })
  local win = maki.ui.open_win(buf, {
    title = " " .. title .. " ", width = "75%", height = height,
    needs_input = true, footer = { { "Enter", "accept" }, { "Esc", "cancel" } },
  })
  return buf, win
end

-- Masked when secret is true (shows asterisks). Returns trimmed text, or
-- nil when cancelled (Esc / window close).
function M.prompt(title, initial, secret, hint)
  local buf, win = M.window(title, 6)
  local text = initial or ""
  while true do
    buf:set_lines({ hint or "", "", secret and string.rep("*", #text) or text })
    local ev = win:recv()
    if not ev or ev.type == "close" or ev.key == "<Esc>" then break end
    if ev.key == "<CR>" then
      win:close()
      return M.trim(text)
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

return M
