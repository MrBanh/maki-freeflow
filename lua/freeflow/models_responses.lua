-- freeflow-responses model rows: the 2 OpenCode Zen muse-spark models
-- whose upstream API is openai-responses and which HARD-require the
-- /v1/responses path (proxy.ts warns on chat-path use; Kilo picks the
-- responses URL by pathname ending in /responses).
--
-- Transcribed from pi-freeflow src/models.ts (pinned version, see vendor/VENDORED.md).
-- No thinking_fields here: effort rides via the build_body hook
-- (opts.thinking -> body.reasoning.effort), which the daemon clamps
-- per model in normalizeResponsesBody.
--
-- Pure data: no `maki` references, loadable by plain lua for tests.

local ZERO = { input = 0, output = 0, cache_write = 0, cache_read = 0 }

local ROWS = {
  {
    prefixes = { "muse-spark-1.2-contributor-free" },
    tier = "medium",
    context_window = 1048576,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
  },
  {
    prefixes = { "muse-spark-1.3-contributor-free" },
    tier = "strong",
    context_window = 1048576,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
  },
}

return ROWS
