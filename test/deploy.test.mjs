import assert from "node:assert/strict";
import { test, after } from "node:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const dir = mkdtempSync(join(tmpdir(), "maki-freeflow-deploy-"));
process.env.PI_FREEFLOW_DATA_DIR = dir;
const { deployRelay } = await import("../vendor/maki-deploy.ts");
const relay = await import("../vendor/src/relay-state.ts");
const deploy = await import("../vendor/src/deploy.ts");
const originalFetch = globalThis.fetch;
const originalTimeout = globalThis.setTimeout;
// Exercise build polling without waiting seconds between mock responses.
globalThis.setTimeout = (fn, ms, ...args) => originalTimeout(fn, Math.min(ms, 10), ...args);
after(() => {
 globalThis.fetch = originalFetch;
 globalThis.setTimeout = originalTimeout;
 rmSync(dir, { recursive: true, force: true });
});
const json = (body, status = 200) => new Response(JSON.stringify(body), { status });
const token = "test-platform-token-never-persist";
let embeddedAuth;
function checkWorker(source) {
 embeddedAuth = JSON.parse(source.match(/const RELAY_AUTH = (.*);/)[1]);
 assert.match(embeddedAuth, /^[a-f0-9]{64}$/);
 assert.ok(!source.includes(token));
 assert.ok(source.includes('"https://opencode.ai", "https://api.kilo.ai"'));
}

test("all platform deployers register private relays, preserve labels, and probe with auth", async (t) => {
 for (const platform of ["cloudflare", "deno", "vercel"]) {
  await t.test(platform, async () => {
   const host = platform === "cloudflare" ? "my-relay.account.workers.dev"
    : platform === "deno" ? "my-relay.deno.net" : "my-relay.vercel.app";
   relay.withRelayState((s) => {
    s.relays = [];
    const r = relay.ensureRelay(s, `https://${host}`, "custom-name");
    r.auth = "old-secret";
    s.url = r.url;
    s.mode = "spread";
    return s;
   });
   const calls = [];
   let polls = 0;
   globalThis.fetch = async (url, init = {}) => {
    url = String(url);
    calls.push([url, init.method || "GET"]);
    if (url.startsWith(`https://${host}/`)) {
     assert.equal(init.headers["x-relay-auth"], embeddedAuth);
     assert.equal(init.headers["x-relay-target"], "https://opencode.ai");
     assert.equal(init.headers["x-relay-path"], "/zen/v1/models");
     return json({ data: [] });
    }
    assert.equal(init.headers.Authorization, `Bearer ${token}`);
    if (url.endsWith("/accounts")) return json({ result: [{ id: "account" }] });
    if (url.endsWith("/workers/scripts/my-relay") && init.method === "PUT") {
     checkWorker(await init.body.get("index.js").text());
     const metadata = JSON.parse(await init.body.get("metadata").text());
     assert.equal(metadata.main_module, "index.js");
     return json({ success: true });
    }
    if (url.endsWith("/workers/scripts/my-relay/subdomain")) return json({ success: true });
    if (url.endsWith("/workers/subdomain")) return json({ result: { subdomain: "account" } });
    if (url.endsWith("/apps") && init.method === "POST") {
     assert.equal(JSON.parse(init.body).slug, "my-relay");
     return json({ id: "app-id" });
    }
    if (url.endsWith("/apps/app-id/deploy")) {
     checkWorker(JSON.parse(init.body).assets["main.ts"].content);
     return json({ id: "revision-id" });
    }
    if (url.endsWith("/revisions/revision-id")) {
     return json(++polls === 1 ? { status: "pending" } : {
      status: "succeeded", timelines: [
       { name: "Preview", context: "Preview", hostnames: ["preview.deno.net"] },
       { name: "Production", context: "Production", hostnames: [host] },
      ],
     });
    }
    if (url.endsWith("/v13/deployments") && init.method === "POST") {
     const body = JSON.parse(init.body);
     assert.equal(body.name, "my-relay");
     assert.equal(body.files.length, 3);
     checkWorker(body.files.find((f) => f.file === "api/relay.js").data);
     return json({ id: "deployment-id", projectId: "project-id" });
    }
    if (url.endsWith("/v9/projects/project-id")) {
     assert.deepEqual(JSON.parse(init.body), { ssoProtection: null });
     return json({});
    }
    if (url.endsWith("/v13/deployments/deployment-id")) {
     return json(++polls === 1 ? { readyState: "BUILDING" } : { readyState: "READY", url: host });
    }
    throw new Error(`Unexpected request: ${url}`);
   };
   const progress = [];
   const result = await deployRelay(platform, token, "My Relay", (m) => progress.push(m));
   assert.equal(result.url, `https://${host}`);
   assert.equal(result.poolSaved, true);
   assert.equal(result.probe.ok, true);
   assert.ok(progress.length >= 4);
   assert.ok(!JSON.stringify(result).includes(embeddedAuth));
   const state = relay.loadRelayState();
   assert.equal(state.mode, "spread");
   assert.equal(state.enabled, true);
   assert.equal(state.relays[0].label, "custom-name");
   assert.equal(state.relays[0].auth, embeddedAuth);
   assert.ok(!readFileSync(join(dir, "pi-freeflow-relay-state.json"), "utf8").includes(token));
   assert.ok(calls.length >= 4);
  });
 }
});

test("invalid names and platforms are rejected before any API request", async () => {
 globalThis.fetch = () => { throw new Error("must not reach network"); };
 await assert.rejects(deployRelay("other", token, "relay"), /Unknown platform/);
 await assert.rejects(deployRelay("deno", token, "!!!"), /no usable/);
 await assert.rejects(deployRelay("cloudflare", token, "a".repeat(59)), /max 58/);
 await assert.rejects(deployRelay("deno", "", "relay"), /No API token/);
});

test("Deno resolves routing through the dedicated timelines endpoint when revision routing is empty", async () => {
 let deleted = false;
 globalThis.fetch = async (url, init = {}) => {
  url = String(url);
  if (init.method === "DELETE") { deleted = true; return json({}); }
  if (url.endsWith("/apps")) return json({ id: "app" });
  if (url.endsWith("/apps/app/deploy")) return json({ id: "revision" });
  if (url.endsWith("/revisions/revision")) return json({ status: "succeeded", timelines: [] });
  if (url.endsWith("/revisions/revision/timelines")) return json([
   { slug: "production", domains: [{ domain: "relay.org.deno.net" }] },
  ]);
  throw new Error(`Unexpected request: ${url}`);
 };
 const result = await deploy.deployDenoRelay(token, "relay");
 assert.equal(result.url, "https://relay.org.deno.net");
 assert.equal(deleted, false);
});

test("failed propagation probes retry and keep the authenticated deployment in the pool", async () => {
 let probes = 0;
 const host = "retry-relay.account.workers.dev";
 globalThis.fetch = async (url, init = {}) => {
  url = String(url);
  if (url.startsWith(`https://${host}/`)) { probes++; return json({}, 503); }
  if (url.endsWith("/accounts")) return json({ result: [{ id: "account" }] });
  if (init.method === "PUT" || init.method === "POST") return json({ success: true });
  if (url.endsWith("/workers/subdomain")) return json({ result: { subdomain: "account" } });
  throw new Error(`Unexpected request: ${url}`);
 };
 const messages = [];
 const result = await deployRelay("cloudflare", token, "retry-relay", (m) => messages.push(m));
 assert.equal(probes, 6);
 assert.equal(result.probe.ok, false);
 assert.equal(result.poolSaved, true);
 assert.equal(relay.loadRelayState().url, `https://${host}`);
 assert.equal(messages.filter((m) => m.includes("propagate")).length, 5);
});

test("upstream deployers clean up failed resources on all platforms", async (t) => {
 for (const platform of ["cloudflare", "deno", "vercel"]) {
  await t.test(platform, async () => {
   let deleted = false;
   globalThis.fetch = async (url, init = {}) => {
    url = String(url);
    if (init.method === "DELETE") { deleted = true; return json({}); }
    if (url.endsWith("/accounts")) return json({ result: [{ id: "account" }] });
    if (init.method === "PUT" || init.method === "PATCH") return json({});
    if (url.endsWith("/workers/scripts/relay/subdomain")) return json({});
    if (url.endsWith("/workers/subdomain")) return json({ result: {} });
    if (url.endsWith("/apps")) return json({ id: "app" });
    if (url.endsWith("/apps/app/deploy")) return json({ error: { message: "upload failed" } }, 500);
    if (url.endsWith("/v13/deployments")) return json({ id: "dep" });
    if (url.endsWith("/v13/deployments/dep")) return json({ readyState: "ERROR" });
    throw new Error(`Unexpected request: ${url}`);
   };
   const deployer = { cloudflare: deploy.deployCloudflareWorker, deno: deploy.deployDenoRelay, vercel: deploy.deployVercelRelay }[platform];
   await assert.rejects(deployer(token, "relay"));
   assert.equal(deleted, true);
  });
 }
});

test("worker auth and guarded forwarding operate in every platform wrapper", async () => {
 for (const builder of [deploy.buildCloudflareRelayWorker, deploy.buildVercelRelayWorker, deploy.buildDenoRelayScript]) {
  const source = builder("relay-secret");
  // Extract the canonical core before the platform entry point.
  const core = source.split(/\nexport |\nDeno\.serve/)[0];
  const handler = new Function("fetch", `${core}; return relayHandler;`)(async (url, init) => {
   assert.equal(url, "https://opencode.ai/zen/v1/models");
   assert.equal(init.headers.get("x-relay-auth"), null);
   assert.equal(init.headers.get("x-relay-target"), null);
   return new Response("streamed response");
  });
  const request = (target, path, auth = "relay-secret") => new Request("https://relay.example", {
   headers: { "x-relay-target": target, "x-relay-path": path, "x-relay-auth": auth },
  });
  assert.equal((await handler(request("https://opencode.ai", "/", "wrong"))).status, 401);
  assert.equal((await handler(request("https://127.0.0.1", "/"))).status, 403);
  assert.equal((await handler(request("https://opencode.ai", "//evil.example/path"))).status, 403);
  assert.equal(await (await handler(request("https://opencode.ai", "/zen/v1/models"))).text(), "streamed response");
 }
});

test("deploy runner accepts environment input and returns safe JSON on failure", () => {
 const result = spawnSync(process.execPath, ["--experimental-strip-types", "vendor/maki-deploy.mjs"], {
  cwd: new URL("..", import.meta.url), encoding: "utf8",
  env: { ...process.env, MAKI_FREEFLOW_DEPLOY: JSON.stringify({ platform: "deno", token, name: "!" }) },
 });
 assert.equal(result.status, 0);
 const event = JSON.parse(result.stdout.trim());
 assert.equal(event.type, "result");
 assert.equal(event.ok, false);
 assert.ok(!result.stdout.includes(token));
});
