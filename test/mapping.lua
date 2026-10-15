package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local mapping = require("freeflow.mapping")
local chat_rows = require("freeflow.models_chat")
local resp_rows = require("freeflow.models_responses")

local index = mapping.index_rows(chat_rows)
for _, row in ipairs(resp_rows) do
  for _, prefix in ipairs(row.prefixes or {}) do
    if index[prefix] == nil then index[prefix] = row end
  end
end

-- Known ids map onto static rows with full specs.
local mapped = mapping.map_daemon_models({ data = {
  { id = "space-bunny", owned_by = "opencode" },
  { id = "ovh-free/gpt-oss-120b", owned_by = "ovhcloud" },
} }, index)
assert(#mapped == 2)
assert(mapped[1].id == "space-bunny-free")
assert(mapped[1].context_window == 1048576)
assert(mapped[1].tier == "medium")
assert(mapped[2].id == "ovh-free/gpt-oss-120b")

-- Unknown OpenCode-lane ids pass through as conservative bare rows.
mapped = mapping.map_daemon_models({ data = {
  { id = "future-model-free", owned_by = "opencode" },
} }, index)
assert(#mapped == 1, "opencode unknown id must pass through")
local bare = mapped[1]
assert(bare.id == "future-model-free")
assert(bare.tier == "medium")
assert(bare.supports_thinking == false)
assert(bare.supports_vision == false)
assert(bare.context_window == 262144)
assert(bare.max_output_tokens == 32768)
assert(bare.pricing.input == 0 and bare.pricing.output == 0)
assert(bare.thinking_fields == nil, "passthrough must not offer effort levels")

-- Unknown ids on other lanes stay hidden: the daemon would misroute them.
mapped = mapping.map_daemon_models({ data = {
  { id = "future-kilo-free", owned_by = "kilocode" },
  { id = "future-cline", owned_by = "clinecode" },
  { id = "ovh-free/future", owned_by = "ovhcloud" },
  { id = "mystery-model" },
  "bare-string-id",
  { id = "" },
  {},
} }, index)
assert(#mapped == 0, "non-opencode unknown ids must stay hidden")

-- Static transcription still covers every known daemon id shape.
assert(index["deepseek-v4.1-flash-free"] ~= nil)
assert(index["gpt-oss-120b"] ~= nil)
assert(index["muse-spark-1.2-contributor-free"] ~= nil)
print("mapping Lua checks passed")
