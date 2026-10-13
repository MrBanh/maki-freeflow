// Maki command adapter. Keep platform APIs and worker templates in upstream deploy.ts.
import {
 deployCloudflareWorker, deployDenoRelay, deployVercelRelay,
 type DeployPlatform,
} from "./src/deploy.ts";
import { validateDeployProjectName } from "./src/commands.ts";
import { ensureRelay, loadRelayState, withRelayState } from "./src/relay-state.ts";
import { probeRelay } from "./src/probe.ts";

export async function deployRelay(
 platform: DeployPlatform,
 token: string,
 name: string,
 onProgress: (message: string) => void = () => {},
) {
 const deployer = { cloudflare: deployCloudflareWorker, deno: deployDenoRelay, vercel: deployVercelRelay }[platform];
 if (!deployer) throw new Error("Unknown platform. Use: cloudflare | deno | vercel");
 if (!token.trim()) throw new Error("No API token provided");
 const check = validateDeployProjectName(name, platform);
 if (!check.ok) throw new Error(check.reason);
 const { url, auth } = await deployer(token.trim(), name, onProgress);
 const finalUrl = url.trim().replace(/\/+$/, "");
 onProgress("Saving authenticated relay to the pool…");
 withRelayState((state) => {
  const previousLabel = state.relays.find((r) => r.url === finalUrl)?.label;
  const entry = ensureRelay(state, finalUrl, `deployed ${check.name}`);
  entry.auth = auth;
  if (previousLabel && !previousLabel.startsWith("deployed ")) entry.label = previousLabel;
  state.enabled = true;
  state.url = finalUrl;
  return state;
 });
 // Upstream persistence can swallow disk errors. Check the secret as well as the URL.
 const saved = loadRelayState();
 const poolSaved = saved.enabled && saved.url === finalUrl
  && saved.relays.some((r) => r.url === finalUrl && r.auth === auth);
 onProgress("Checking relay reachability…");
 const probe = await probeRelay(finalUrl, auth, {
  retries: 5,
  retryDelayMs: 2000,
  onRetry: (attempt, total) => onProgress(`Waiting for edge routing to propagate (${attempt}/${total})…`),
 });
 // Only the relay-state file gets the shared secret; never send it to the UI/job output.
 return { url: finalUrl, poolSaved: Boolean(poolSaved), probe };
}
