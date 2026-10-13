import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

test("fresh checkout installs its pinned dependency, imports daemon, and skips repeat installs", () => {
  const dir = mkdtempSync(join(tmpdir(), "maki-freeflow-setup-"));
  try {
    // Spaces in checkout paths must work without shell quoting or a custom loader.
    const vendor = join(dir, "managed checkout", "vendor");
    mkdirSync(vendor, { recursive: true });
    for (const file of ["package.json", "package-lock.json", "maki-setup.mjs", "src"]) {
      cpSync(new URL(`../vendor/${file}`, import.meta.url), join(vendor, file), { recursive: true });
    }
    const run = (args, env = process.env) => spawnSync(process.execPath, args, {
      cwd: vendor, encoding: "utf8", timeout: 150000, env,
    });
    // Missing npm produces an actionable repair message and can be retried.
    let result = run(["maki-setup.mjs"], { ...process.env, PATH: "" });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /dependency setup failed/);
    assert.ok(result.stderr.includes(vendor));

    result = run(["maki-setup.mjs"]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Installing FreeFlow/);
    result = run(["maki-setup.mjs"], { ...process.env, PATH: "" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "", "installed checkout must not invoke npm again");
    result = run(["--experimental-strip-types", "--input-type=module", "-e", "await import('./src/daemon.ts')"], {
      ...process.env, PI_FREEFLOW_DATA_DIR: dir,
    });
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
