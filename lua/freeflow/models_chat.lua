-- freeflow model rows: 33 chat-completions models served through the
-- vendored pi-freeflow daemon on 127.0.0.1:28180.
--
-- Transcribed from pi-freeflow src/models.ts (pinned version, see vendor/VENDORED.md):
--   9 OpenCode Zen chat models + 14 Kilo Gateway models + 2 Cline models + 8 OVH models.
-- The 2 Zen muse-spark responses-API models live in models_responses.lua;
-- cline-free/muse-spark-1.3-contributor rides HERE because the daemon
-- translates responses<->chat for it daemon-side (works on either path).
--
-- Tier choices (pi has no tiers; maki needs one, default medium):
--   strong: 1M-context flagships and big reasoning models
--     step-5-preview-free, dots-3-note-preview, deepseek-v4.1-flash-free,
--     gpt-oss-120b, qwen3.5-397b (+ muse-spark-1.3 on the responses provider)
--   weak: small/fast/router models
--     nemotron-3.5-lightning-free, lfm-2.5,
--     kilo-auto, openrouter-auto, north-mini-code, laguna-xs
--   medium: everything else.
--
-- thinking_fields: each valid effort level from the model's thinkingLevelMap
-- maps to { reasoning_effort = <verbatim value> }. The daemon reads the flat
-- reasoning_effort field and clamps unsupported levels per model
-- (enforceOpencodeFingerprint/normalizeResponsesBody), so maki levels that
-- snap onto an undeclared key are still safe downstream. `off` is omitted on
-- every row: with thinking_fields declared, an omitted mode sends nothing.
-- Pricing is 0/0 everywhere (free tiers).
--
-- Pure data: no `maki` references, loadable by plain lua for tests.

-- Build { level = { reasoning_effort = value } }, skipping null (nil) levels.
local function tf(levels)
  local out = {}
  for level, value in pairs(levels) do
    if value ~= nil then
      out[level] = { reasoning_effort = value }
    end
  end
  return out
end

local ZERO = { input = 0, output = 0, cache_write = 0, cache_read = 0 }

-- Shared Kilo reasoning map: minimal..xhigh verbatim, max unsupported.
local function kilo_tf()
  return tf({ minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh" })
end

-- Narrow Cline flash map: low/high/max only.
local function cline_flash_tf()
  return tf({ low = "low", high = "high", max = "max" })
end

-- Narrow OVH reasoning map: low/high only (live-probed 2026-10-13).
local function ovh_tf()
  return tf({ low = "low", high = "high" })
end

local ROWS = {
  -- ── OpenCode Zen chat models ──────────────────────────────────────
  {
    prefixes = { "cat-jam-free" },
    tier = "medium",
    context_window = 262144,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = tf({ low = "low", medium = "medium", high = "high", xhigh = "xhigh" }),
  },
  {
    prefixes = { "mimo-v2.6-flash-free", "mimo-v2.6-flash" },
    tier = "medium",
    context_window = 1048576,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = tf({ minimal = "low", low = "low", medium = "medium", high = "high", xhigh = "high" }),
  },
  {
    prefixes = { "nemotron-3-ultra-free" },
    tier = "medium",
    context_window = 1000000,
    max_output_tokens = 128000,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = tf({ minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh" }),
  },
  {
    prefixes = { "nemotron-3.5-lightning-free" },
    tier = "weak",
    context_window = 1000000,
    max_output_tokens = 262144,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = tf({ minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh" }),
  },
  {
    prefixes = { "big-pickle" },
    tier = "medium",
    context_window = 200000,
    max_output_tokens = 32000,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = tf({ high = "high", max = "max" }),
  },
  {
    prefixes = { "space-bunny-free", "space-bunny" },
    tier = "medium",
    context_window = 1048576,
    max_output_tokens = 524288,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = tf({ low = "low", medium = "medium", high = "high", xhigh = "xhigh", max = "max" }),
  },
  {
    prefixes = { "longcat-2.5-preview-free", "longcat-2.5-preview", "longcat" },
    tier = "medium",
    context_window = 1000000,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = tf({ minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh", max = "max" }),
  },
  {
    prefixes = { "step-5-preview-free", "step-5-preview" },
    tier = "strong",
    context_window = 1000000,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = tf({ low = "low", medium = "medium", high = "high" }),
  },
  {
    prefixes = { "deepseek-v4.1-flash-free", "deepseek-v4.1-flash" },
    tier = "strong",
    context_window = 1048576,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = tf({ minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh", max = "max" }),
  },
  -- ── Kilo Gateway models ───────────────────────────────────────────
  {
    prefixes = { "dots-studio/dots-3-note-preview:free", "dots-3-note-preview" },
    tier = "strong",
    context_window = 512000,
    max_output_tokens = 512000,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "nemotron-3-nano-omni" },
    tier = "medium",
    context_window = 256000,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "nvidia/nemotron-3-ultra-550b-a55b:free", "nemotron-3-ultra-550b" },
    tier = "medium",
    context_window = 1000000,
    max_output_tokens = 128000,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "nvidia/nemotron-3.5-lightning:free", "nemotron-3.5-lightning" },
    tier = "medium",
    context_window = 1000000,
    max_output_tokens = 262144,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "nvidia/nemotron-3-super-120b-a12b:free", "nemotron-3-super" },
    tier = "medium",
    context_window = 262144,
    max_output_tokens = 262144,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "cohere/north-mini-code:free", "north-mini-code" },
    tier = "weak",
    context_window = 256000,
    max_output_tokens = 64000,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "poolside/laguna-s-2.1:free", "laguna-s-2.1:free" },
    tier = "medium",
    context_window = 262144,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "poolside/laguna-xs-2.1:free", "laguna-xs-2.1:free" },
    tier = "weak",
    context_window = 262144,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "liquid/lfm-2.5-2.6b:free", "lfm-2.5" },
    tier = "weak",
    context_window = 65536,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "kilo-auto/free", "kilo-auto" },
    tier = "weak",
    context_window = 256000,
    max_output_tokens = 10000,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "openrouter/free", "openrouter" },
    tier = "weak",
    context_window = 200000,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "stepfun/step-5-preview-free", "step-5-preview:kilo" },
    tier = "medium",
    context_window = 1000000,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "thinkingmachines/inkling-small:free", "inkling-small" },
    tier = "medium",
    context_window = 1048576,
    max_output_tokens = 262144,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  {
    prefixes = { "stealth/glyph-cluster", "glyph-cluster" },
    tier = "medium",
    context_window = 256000,
    max_output_tokens = 256000,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = kilo_tf(),
  },
  -- ── Cline direct-only models ──────────────────────────────────────
  {
    -- Cline muse-spark: responses-API upstream, but the daemon translates
    -- responses<->chat daemon-side, so it rides the chat provider.
    prefixes = { "cline-free/muse-spark-1.3-contributor" },
    tier = "medium",
    context_window = 1048576,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = tf({ minimal = "minimal", low = "low", medium = "medium", high = "high", xhigh = "xhigh" }),
  },
  {
    prefixes = { "z-ai/glm-5.3-flash" },
    tier = "medium",
    context_window = 1048576,
    max_output_tokens = 131072,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = cline_flash_tf(),
  },
  -- ── OVHcloud AI Endpoints direct-only models (keyless, no relay) ──
  {
    prefixes = { "ovh-free/gpt-oss-120b", "gpt-oss-120b" },
    tier = "strong",
    context_window = 131072,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = ovh_tf(),
  },
  {
    prefixes = { "ovh-free/gpt-oss-20b", "gpt-oss-20b" },
    tier = "medium",
    context_window = 131072,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = false,
    pricing = ZERO,
    thinking_fields = ovh_tf(),
  },
  {
    prefixes = { "ovh-free/Qwen3.5-397B-A17B", "qwen3.5-397b" },
    tier = "strong",
    context_window = 262144,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = ovh_tf(),
  },
  {
    prefixes = { "ovh-free/Qwen3.5-9B", "qwen3.5-9b" },
    tier = "medium",
    context_window = 262144,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = ovh_tf(),
  },
  {
    prefixes = { "ovh-free/Qwen3.6-27B", "qwen3.6-27b" },
    tier = "medium",
    context_window = 262144,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = ovh_tf(),
  },
  {
    prefixes = { "ovh-free/Qwen3.8-27B", "qwen3.8-27b" },
    tier = "medium",
    context_window = 262144,
    max_output_tokens = 32768,
    supports_thinking = true,
    supports_vision = true,
    pricing = ZERO,
    thinking_fields = ovh_tf(),
  },
  {
    prefixes = { "ovh-free/Mistral-Small-3.2-24B-Instruct-2506", "mistral-small-3.2" },
    tier = "medium",
    context_window = 131072,
    max_output_tokens = 16384,
    supports_thinking = false,
    supports_vision = true,
    pricing = ZERO,
  },
  {
    prefixes = { "ovh-free/Meta-Llama-3_3-70B-Instruct", "llama-3.3-70b" },
    tier = "medium",
    context_window = 131072,
    max_output_tokens = 16384,
    supports_thinking = false,
    supports_vision = false,
    pricing = ZERO,
  },
}

return ROWS
