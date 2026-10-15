# Sync runbook — upstream pi-freeflow → maki-freeflow

Upstream: https://github.com/trefeon/pi-freeflow (pinned state: `vendor/VENDORED.md`).

## When NOT to sync

New-model churn on the OpenCode lane needs nothing: the daemon merges new
upstream free models into its live catalog via background refresh, and
`mapping.map_daemon_models` passes unknown `owned_by == "opencode"` ids
through as conservative rows (medium, 256K ctx, no effort/vision flags).
They appear in the picker and route correctly with zero repo changes.
Sync only to transcribe full specs, or for the cases below.

## When to sync

- New Kilo/Cline/OVH-lane models (Lua hides them: the daemon routes those
  lanes by static id sets, so they'd misroute until transcribed).
- Proxy behavior changes (tool repair, fingerprint, failover, endpoints).
- New `/freeflow` subcommands (audit `command.lua` CUT).
- Anything in "human review" failing after the mechanical steps.

## Procedure (run from repo root)

1. Check upstream state (record HEAD SHA + latest tag + package version):
   ```
   git ls-remote https://github.com/trefeon/pi-freeflow.git HEAD
   git ls-remote --tags https://github.com/trefeon/pi-freeflow.git | tail -5
   ```
   Fetch the file to compare (adjust ref for a tag target):
   ```
   curl -s https://raw.githubusercontent.com/trefeon/pi-freeflow/main/package.json | grep '"version"'
   ```
2. Refresh the reference clones (or re-clone if stale):
   ```
   git clone --depth 1 https://github.com/trefeon/pi-freeflow.git /tmp/pi-freeflow-upstream
   ```
3. Diff and copy the daemon (27 files; never touch `vendor/maki-*` shims):
   ```
   diff -rq /tmp/pi-freeflow-upstream/src vendor/src
   cp /tmp/pi-freeflow-upstream/src/*.ts vendor/src/
   ```
4. Bump versions to match upstream `package.json` (`version` field in
   `vendor/package.json` plus the two `1.x` version fields in
   `vendor/package-lock.json`; deps are normally unchanged — verify
   `undici` matches or reinstall `vendor/node_modules`).
5. Regenerate the Lua tables (never hand-edit the row files):
   ```
   node scripts/generate-lua-models.mjs
   git diff lua/freeflow/models_chat.lua lua/freeflow/models_responses.lua
   ```
   New models with no tier judgment land on `medium` — promote flagships
   to `STRONG` / demote routers to `WEAK` in the script, then re-run.
6. Human review (the only non-mechanical step):
   - `diff /tmp/pi-freeflow-upstream/src/deploy.ts vendor/src/deploy.ts`
     must show ONLY the Deno hostname patch (or nothing, if upstream
     finally took it — then drop the patch and this bullet).
     Re-apply from the previous commit if the copy wiped it.
   - New upstream subcommands (`grep -n 'sub ===' vendor/src/commands.ts`):
     support or add to `command.lua` CUT with a reason.
   - `vendor/maki-deploy.ts` / `maki-cline.ts` imports still exist upstream
     (`deployCloudflareWorker`, `validateDeployProjectName`, `ensureRelay`,
     `probeRelay`, `addAccount`, `startDeviceAuth`, …).
7. Update `vendor/VENDORED.md` (HEAD SHA, version, patch status, gap notes).
8. Verify (all must pass):
   ```
   node scripts/generate-lua-models.mjs --check
   node --experimental-strip-types --input-type=module -e "await import('./vendor/src/daemon.ts')"
   node --test test/setup.test.mjs test/deploy.test.mjs test/cline.test.mjs test/models.test.mjs
   lua test/deploy.lua && lua test/setup.lua && lua test/cline.lua && lua test/mapping.lua
   ```
9. Commit, push, tag per maintainer instruction (history: `v0.2.0` pattern,
   GitHub release with notes).
