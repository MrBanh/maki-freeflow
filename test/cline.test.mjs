import assert from "node:assert/strict";
import { test, after } from "node:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "maki-freeflow-cline-"));
process.env.PI_FREEFLOW_DATA_DIR = dir;
const { runCline } = await import("../vendor/maki-cline.ts");
const poolFile = join(dir, "pi-freeflow-cline-pool.json");
after(() => {
  rmSync(dir, { recursive: true, force: true });
});

const json = (body, status = 200) => new Response(JSON.stringify(body), { status });
const device = { device_code: "dev-code", user_code: "ABCD-1234", verification_uri: "https://app.cline.bot/device", verification_uri_complete: "https://app.cline.bot/device?code=ABCD-1234", expires_in: 300, interval: 1 };
const tokens = (access, email, userId, refresh = "refresh-1") => json({ success: true, data: { accessToken: access, refreshToken: refresh, tokenType: "Bearer", expiresAt: new Date(Date.now() + 3600_000).toISOString(), userInfo: { email, clineUserId: userId } } });
const jwt = (exp, sub) => {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64({ alg: "ES256" })}.${b64({ exp, sub })}.sig`;
};

// Device flow: one pending poll, then tokens, then registration.
function mockDeviceFlow(email, userId) {
  const access = jwt(Math.floor(Date.now() / 1000) + 3600, userId);
  let polls = 0;
  globalThis.fetch = async (url) => {
    url = String(url);
    if (url.endsWith("/user_management/authorize/device")) return json(device);
    if (url.endsWith("/user_management/authenticate")) {
      polls++;
      if (polls === 1) return json({ error: "authorization_pending" }, 400);
      return json({ access_token: access, refresh_token: "refresh-1" });
    }
    if (url.endsWith("/api/v1/auth/register")) return tokens(access, email, userId);
    throw new Error(`Unexpected request: ${url}`);
  };
}

test("device login saves to the next free slot with redacted display", async () => {
  mockDeviceFlow("a@example.com", "user-1");
  const progress = [];
  const result = await runCline({ op: "login" }, (m) => progress.push(m));
  assert.equal(result.slot, "default");
  assert.match(result.redacted, /^…/);
  assert.equal(result.count, 1);
  assert.equal(result.lines.length, 1);
  assert.ok(progress[0].includes("ABCD-1234"));
  assert.ok(progress[0].includes("https://app.cline.bot/device?code=ABCD-1234"));
  const saved = JSON.parse(readFileSync(poolFile, "utf8"));
  assert.equal(saved.accounts.length, 1);
  assert.equal(saved.accounts[0].slot, "default");
  assert.ok(saved.accounts[0].token.startsWith("workos:"));
  assert.ok(saved.accounts[0].refreshToken, "device grant keeps its refresh token");
  assert.ok(!JSON.stringify(result).includes(saved.accounts[0].token), "full token never leaves in results");
  assert.ok(!progress.join("\n").includes(saved.accounts[0].token));
});

test("second login takes slot-2 and duplicate accounts are refused", async () => {
  mockDeviceFlow("b@example.com", "user-2");
  const second = await runCline({ op: "login", slot: "" }, () => {});
  assert.equal(second.slot, "slot-2");
  assert.equal(second.count, 2);
  // The same account twice shares one quota: refused, never saved twice.
  await assert.rejects(runCline({ op: "login", slot: "slot-3" }, () => {}), /already saved as/);
});

test("accounts lists logins, logout resolves slots and indexes", async () => {
  const listed = await runCline({ op: "accounts" });
  assert.equal(listed.count, 2);
  assert.ok(listed.lines[0].includes("[default]"));
  const byIndex = await runCline({ op: "logout", slot: "2" });
  assert.equal(byIndex.removed, "slot-2");
  assert.equal(byIndex.count, 1);
  await assert.rejects(runCline({ op: "logout", slot: "nope" }), /not found/);
  const last = await runCline({ op: "logout" });
  assert.equal(last.removed, "default");
  assert.equal(last.count, 0);
  await assert.rejects(runCline({ op: "logout" }), /nothing to remove/);
});

test("save-key accepts workos grants and clp keys, rejects junk", async () => {
  const saved = await runCline({ op: "save-key", slot: "manual", token: "workos:grant-token" });
  assert.equal(saved.slot, "manual");
  await runCline({ op: "logout", slot: "manual" });
  await runCline({ op: "save-key", slot: "", token: "clp_testkey" });
  await assert.rejects(runCline({ op: "save-key", token: "not-a-key" }), /must be a workos:/);
  await assert.rejects(runCline({ op: "save-key", token: "" }), /no API key/);
  await runCline({ op: "logout" });
});

test("cancelled and expired device codes map to actionable errors", async () => {
  globalThis.fetch = async (url) => {
    url = String(url);
    if (url.endsWith("/user_management/authorize/device")) return json(device);
    if (url.endsWith("/user_management/authenticate")) return json({ error: "access_denied", error_description: "denied" }, 400);
    throw new Error(`Unexpected request: ${url}`);
  };
  await assert.rejects(runCline({ op: "login" }, () => {}), /cancelled/);
  globalThis.fetch = async (url) => {
    url = String(url);
    if (url.endsWith("/user_management/authorize/device")) return json(device);
    if (url.endsWith("/user_management/authenticate")) return json({ error: "expired_token", error_description: "expired" }, 400);
    throw new Error(`Unexpected request: ${url}`);
  };
  await assert.rejects(runCline({ op: "login", slot: "x" }, () => {}), /expired/);
});

test("unreachable WorkOS reports a cert-aware error, unknown ops show usage", async () => {
  globalThis.fetch = async () => { throw new Error("fetch failed"); };
  await assert.rejects(runCline({ op: "login" }, () => {}), /Could not reach Cline/);
  await assert.rejects(runCline({ op: "bogus" }), /cline login/);
  const signout = await runCline({ op: "signout" });
  assert.ok(signout.message.includes("https://"));
  assert.ok(signout.message.includes("next is default"));
});
