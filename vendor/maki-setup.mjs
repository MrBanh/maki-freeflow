// First-use setup for this checkout; no third-party dependencies needed.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const require = createRequire(import.meta.url);
const vendor = fileURLToPath(new URL(".", import.meta.url));
const expected = JSON.parse(readFileSync(new URL("package.json", import.meta.url))).dependencies.undici;
function installed() {
  try { return require("undici/package.json").version === expected; }
  catch { return false; }
}

if (!installed()) {
  console.log("Installing FreeFlow runtime dependencies for this checkout…");
  const result = spawnSync("npm", ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], {
    cwd: vendor, stdio: "inherit", timeout: 120000,
  });
  if (result.error || result.status !== 0) {
    console.error("FreeFlow dependency setup failed: " + (result.error?.message ?? `npm exited ${result.status}`));
    console.error(`Run npm ci --omit=dev in ${vendor}, then /freeflow status.`);
    process.exit(1);
  }
}
if (!installed()) {
  console.error("FreeFlow dependency setup did not install the expected undici version.");
  process.exit(1);
}
await import("undici");
