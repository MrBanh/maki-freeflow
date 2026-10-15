# Vendor provenance — pi-freeflow

Upstream: https://github.com/trefeon/pi-freeflow (MIT © trefeon)

This directory vendors the upstream Node daemon that owns
`127.0.0.1:28180` and all routing/upstream logic. Maki-side Lua
(`lua/freeflow/`, `plugin/`) is a thin lifecycle + provider layer on top;
it never re-implements daemon logic.

## Currently aligned with

- **Upstream main HEAD: 384628fa1128bf688e243129e23b203d1d785323**
  ("feat(catalog): add DeepSeek V4.1 Flash free model to the OpenCode
  lane (#55)", 2026-10-15) — one commit past tag v1.37.0
  (ede808a4020b68a6fc8f5b011b1f7a0553ec3918).
- **Machine-readable version:** `vendor/package.json` → `"version": "1.37.0"`
  (checked at runtime by `lua/freeflow/daemon.lua` `vendor_version()`
  against the daemon `/_health` version).
- **Lua model tables** transcribed from the same HEAD:
  `lua/freeflow/models_chat.lua` (33 chat rows: 9 OpenCode + 14 Kilo +
  2 Cline + 8 OVH) and `lua/freeflow/models_responses.lua`
  (2 OpenCode muse-spark rows).

Quick check:

```
grep '"version"' vendor/package.json
git log --oneline -3 -- vendor/src/
diff -rq /tmp/pi-freeflow-upstream/src vendor/src  # expect only deploy.ts
```

## What is vendored

From upstream HEAD:

- `vendor/src/*.ts` (27 files) — the daemon, relay pool, deployers, catalog.
- `vendor/package.json`, `vendor/package-lock.json` — identity + pinned `undici`
  (upstream pins the same `undici 7.30.0`; the lockfile is our npm
  translation of their pnpm lock — same dep, same version).
- `vendor/node_modules/` — installed at runtime, git-ignored.

Maki-only files (NOT upstream, do not overwrite on sync):

- `vendor/maki-deploy.ts` / `.mjs` — deploy adapter for Maki windows.
- `vendor/maki-cline.ts` / `.mjs` — Cline pool adapter.
- `vendor/maki-setup.mjs` — dependency installer shim.

Deliberately NOT vendored from upstream:

- `extensions/`, `test/`, `docs/`, `scripts/`
- upstream `README.md`, `CHANGELOG.md`, `LICENSE`
  (attribution lives in `README.md` + `LICENSE` at repo root).

## Local patches on top of upstream

`vendor/src/` differs from upstream HEAD in exactly one file
(verified `diff -rq`):

- `vendor/src/deploy.ts` — Deno Deploy relay hostnames (kept since
  `a1f95bd`, re-applied on this sync because upstream still lacks it):
  `DenoRevision.timelines` also accepts `name`/`context`/`hostnames[]`,
  `resolveRoutedDomain` matches production by slug/name/context
  (case-insensitive) and reads `hostnames[]` as well as `domains[]`,
  plus a `GET /revisions/{id}/timelines` fallback before the org-domain
  list. Covered by `test/deploy.test.mjs`.

Retired local patches (now upstream, dropped on this sync):

- `ded65b2` — OpenCode free tier to `/inference/v1` (upstream `1.36.3`
  did the same migration; vendored tree now matches upstream verbatim
  here, including `Bearer public` headers and no `x-opencode-request`).

## Previous gap, closed by this sync

`v1.34.0 → v1.37.0` per upstream `CHANGELOG.md`:

- `1.35.0` — 9 anonymous OVHcloud AI Endpoints models (+9 / -3 Cline
  retirements); tool-shape `400` hardening.
- `1.36.0` — `cat-jam-free` on OpenCode Zen; spliced tool-arg repair.
- `1.36.1` — broad tool-call JSON/name/shape repair across all lanes.
- `1.36.2` — Zen 403 auto-failover to Kilo; `ling-3.1-flash-free` pruned.
- `1.36.3` — Zen endpoint/gate migration restore (was our `ded65b2`).
- `1.37.0` — `/freeflow autoupdate`, stale-daemon auto-recovery,
  warp-relay-pool VPS docs, doc sync to 34 verified models.
- HEAD `384628f` — DeepSeek V4.1 Flash free on the OpenCode lane.

Lua transcription on this sync: removed 5 retired rows
(`ling-3.1-flash-free`, `ling-3.1-flash:kilo`, `cline-free/deepseek-v4.1-flash`,
`cline-free/kimi-k3`, `cline-free/solar-pro4`), added 10
(`cat-jam-free`, `deepseek-v4.1-flash-free`, 8× `ovh-free/*`);
`28 → 33` chat rows. New upstream commands `autoupdate` / `update auto`
stay cut on Maki (see `command.lua` CUT — a vendored copy never self-updates).

## How to re-sync

1. `git clone --depth 1 https://github.com/trefeon/pi-freeflow.git /tmp/pi-freeflow-upstream`
2. `diff -rq /tmp/pi-freeflow-upstream/src vendor/src` — review.
3. Copy `src/`, `package.json` (keep `maki-*` shims; bump the two
   `1.x` version fields in `package-lock.json` to match).
4. Re-apply (or drop, if upstreamed) the "Local patches" above.
5. Re-transcribe `lua/freeflow/models_*.lua` from the new `src/models.ts`
   (counts, aliases, context/max-output, vision, thinking maps).
6. Update this file's "Currently aligned with" section + HEAD SHA,
   then run `node --test test/setup.test.mjs`,
   `node --experimental-strip-types --test test/deploy.test.mjs`,
   `lua test/deploy.lua`, `lua test/setup.lua`.
