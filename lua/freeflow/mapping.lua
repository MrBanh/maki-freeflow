-- Pure mapping helpers for the freeflow providers. No `maki` references:
-- loadable by plain lua so the row/list/error mapping is unit-testable
-- without network or a running daemon.
local M = {}

-- Mirror of pi-freeflow client.ts proxyDownMessage (maki wording).
function M.proxy_down_message(port)
  return "freeflow proxy is down on 127.0.0.1:"
    .. tostring(port)
    .. " (connection refused) — model requests cannot reach the local proxy."
    .. " Run /freeflow status to respawn it."
end

-- True when a transport/API error string looks like a refused loopback
-- connection to our daemon (as opposed to an upstream failure).
-- Walks the same signals as pi-freeflow isLoopbackRefused: a refusal that
-- mentions loopback.
function M.is_loopback_refused_message(message)
  local m = tostring(message or "")
  local refused = m:find("ECONNREFUSED") ~= nil
    or m:find("[Cc]onnection refused") ~= nil
    or m:find("connection reset") ~= nil
    or m:find("failed to connect") ~= nil
  if not refused then
    return false
  end
  return m:find("127%.0%.0%.1") ~= nil
    or m:find("::1") ~= nil
    or m:find("localhost") ~= nil
    or m:find(":28180") ~= nil
end

-- Provider map_error hook body (shared by both providers).
-- Returns { status, message } to rewrite, or nil to keep the error.
function M.map_error(port, status, message)
  if M.is_loopback_refused_message(message) then
    return { status = status, message = M.proxy_down_message(port) }
  end
  return nil
end

-- Index static rows by every prefix for O(1) lookup.
function M.index_rows(rows)
  local index = {}
  for _, row in ipairs(rows) do
    for _, prefix in ipairs(row.prefixes or {}) do
      if index[prefix] == nil then
        index[prefix] = row
      end
    end
  end
  return index
end

-- Map a daemon GET /v1/models body ({ object="list", data={ {id,...} } })
-- onto list_models rows using the static index for limits/tier/flags.
-- Daemon ids with no static row pass through as bare medium-tier rows so a
-- newer daemon catalog is never hidden by an older plugin copy.
function M.map_daemon_models(body, index)
  local out = {}
  local data = (type(body) == "table" and body.data) or {}
  for _, entry in ipairs(data) do
    local id = type(entry) == "table" and entry.id or entry
    if type(id) == "string" and id ~= "" then
      local row = index[id]
      -- Strict per-provider catalog: daemon models with no row here are
      -- SKIPPED, not listed bare. A bare listing would offer models from the
      -- other provider (e.g. responses-only rows on the chat picker), whose
      -- requests fail downstream (ModelProtocolUnsupported). New daemon
      -- models appear here by transcribing them into the row files.
      if row then
        table.insert(out, {
          id = row.prefixes[1],
          context_window = row.context_window,
          max_output_tokens = row.max_output_tokens,
          pricing = row.pricing,
          supports_thinking = row.supports_thinking,
          supports_vision = row.supports_vision,
          tier = row.tier,
        })
      end
    end
  end
  return out
end

-- Static rows -> list_models fallback rows (used when the daemon is
-- unreachable so the picker is populated pre-daemon, mirroring pi's
-- zero-latency static catalog registration).
function M.static_list_rows(rows)
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, {
      id = row.prefixes[1],
      context_window = row.context_window,
      max_output_tokens = row.max_output_tokens,
      pricing = row.pricing,
      supports_thinking = row.supports_thinking,
      supports_vision = row.supports_vision,
      tier = row.tier,
    })
  end
  return out
end

return M
