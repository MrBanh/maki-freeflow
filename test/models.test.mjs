import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

// The Lua model tables are generated artifacts. If this fails, run
// scripts/generate-lua-models.mjs (or `node scripts/generate-lua-models.mjs`)
// and commit the result — never hand-edit the row files.
test("generated Lua model tables match vendor/src/models.ts", () => {
  const result = spawnSync(process.execPath, ["scripts/generate-lua-models.mjs", "--check"], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr + result.stdout);
});
