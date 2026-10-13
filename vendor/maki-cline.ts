// Maki command adapter for the Cline pool login. The WorkOS device flow,
// token registration, and pool persistence stay in the vendored upstream
// modules (src/cline-device-auth.ts + src/cline-accounts.ts); this file
// only ports the orchestration and pure display helpers from
// src/commands.ts (nextClineSlot, formatClineAccountLines, error mapping),
// following the vendor/maki-deploy.ts adapter pattern.
import {
  addAccount,
  findClineAccountSlot,
  loadPool,
  redactedToken,
  removeAccount,
  type ClinePoolState,
} from "./src/cline-accounts.ts";
import {
  CLINE_BROWSER_SIGNOUT_URL,
  pollDeviceToken,
  registerClineToken,
  startDeviceAuth,
  toApiKey,
} from "./src/cline-device-auth.ts";
import { isCertError } from "./src/system-ca-fetch.ts";

export const CLINE_USAGE =
  "Usage: /freeflow cline login [--key] [slot] | /freeflow cline accounts | /freeflow cline logout [slot] | /freeflow cline signout";

export interface ClineRequest {
  op: string;
  slot?: string;
  token?: string;
}

export type ClineProgress = (message: string) => void;

/** User-safe one-line message for caught values (never echoes secrets). */
function clineErrorMessage(e: unknown): string {
  if (e instanceof Error && e.message) return e.message;
  if (typeof e === "string" && e) return e;
  return "unknown error";
}

/**
 * Pick the login slot when the user gives none: "default" for the first
 * login, then the smallest free "slot-2", "slot-3", … — never overwriting
 * a saved login. Pure — takes the pool, returns a name.
 */
function nextClineSlot(pool: ClinePoolState): string {
  if (!pool.accounts.some((a) => a.slot === "default")) return "default";
  let n = 2;
  while (pool.accounts.some((a) => a.slot === `slot-${n}`)) n += 1;
  return `slot-${n}`;
}

interface ClineUsageRow {
  served: number;
  lastAt: number;
  lastModel: string;
}

function clineUsageRows(pool: ClinePoolState): Record<string, ClineUsageRow> {
  const raw = (pool as unknown as { usage?: unknown }).usage;
  if (!raw || typeof raw !== "object") return {};
  const out: Record<string, ClineUsageRow> = {};
  for (const [slot, entry] of Object.entries(raw as Record<string, unknown>)) {
    if (!entry || typeof entry !== "object") continue;
    const rec = entry as Record<string, unknown>;
    if (typeof rec.served !== "number" || !(rec.served >= 0)) continue;
    out[slot] = {
      served: rec.served,
      lastAt: typeof rec.lastAt === "number" ? rec.lastAt : 0,
      lastModel: typeof rec.lastModel === "string" ? rec.lastModel : "",
    };
  }
  return out;
}

function clineUsageAge(lastAt: number, now = Date.now()): string {
  if (!(lastAt > 0)) return "";
  const diff = now - lastAt;
  if (diff < 0) return new Date(lastAt).toISOString();
  if (diff < 60_000) return "just now";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  if (diff < 30 * 86_400_000) return `${Math.floor(diff / 86_400_000)}d ago`;
  return new Date(lastAt).toISOString();
}

function formatClineUsageSuffix(slot: string, usage: Record<string, ClineUsageRow>, now = Date.now()): string {
  const row = usage[slot];
  if (!row || row.served <= 0) return " · served 0 · never used";
  const age = clineUsageAge(row.lastAt, now);
  const last = row.lastModel ? ` · last ${row.lastModel}${age ? ` ${age}` : ""}` : "";
  return ` · served ${row.served}${last}`;
}

/** One notify-ready line per saved login, in pool order, with usage. */
function formatClineAccountLines(pool: ClinePoolState): string[] {
  const usage = clineUsageRows(pool);
  return pool.accounts.map((a, idx) => {
    const star = a.slot === pool.activeSlot ? "*" : " ";
    const who = a.email || a.accountId;
    const whoPart = who ? ` ${who}` : "";
    const earlier = { accounts: pool.accounts.slice(0, idx) };
    const dup = findClineAccountSlot(earlier, a);
    const dupPart = dup ? ` — same account as [${dup}]` : "";
    return `${star} [${idx + 1}] [${a.slot}]${whoPart} key ending ${redactedToken(a.token)}${dupPart}${formatClineUsageSuffix(a.slot, usage)}`;
  });
}

function formatLoginLine(slot: string, link: string, userCode: string, minutes: number): string {
  return `Cline login [${slot}]\nOpen this link in your browser:\n${link}\nEnter code: ${userCode} (expires in ~${minutes} min)\nWaiting for approval — approve or cancel in the browser; this finishes on its own.\nDifferent account? Sign out first: ${CLINE_BROWSER_SIGNOUT_URL} (or use a private window)`;
}

function savedMessage(slot: string, token: string): string {
  return `Saved Cline login [${slot}] (key ending ${redactedToken(token)}) — free Cline models are ready to use`;
}

export function clineAccounts(): { count: number; lines: string[] } {
  const pool = loadPool();
  return { count: pool.accounts.length, lines: formatClineAccountLines(pool) };
}

export function clineLogout(arg?: string): { removed: string; count: number } {
  const pool = loadPool();
  if (!pool.accounts.length) throw new Error("No Cline logins saved — nothing to remove");
  const clean = (arg || "").trim();
  let slot: string | null = null;
  if (clean) {
    const byIndex = Number.parseInt(clean, 10);
    if (String(byIndex) === clean && byIndex >= 1 && byIndex <= pool.accounts.length) {
      slot = pool.accounts[byIndex - 1].slot;
    } else {
      const exact = pool.accounts.find((a) => a.slot === clean);
      const folded = exact ?? pool.accounts.find((a) => a.slot.toLowerCase() === clean.toLowerCase());
      slot = folded ? folded.slot : null;
    }
    if (!slot) {
      const saved = pool.accounts.map((a, idx) => `${idx + 1}=${a.slot}`).join(", ");
      throw new Error(`Cline slot '${clean}' not found. Saved: ${saved}`);
    }
  } else if (pool.accounts.length === 1) {
    slot = pool.accounts[0].slot;
  } else {
    // No select UI on this host: name the slot explicitly.
    const saved = pool.accounts.map((a, idx) => `${idx + 1}=${a.slot}`).join(", ");
    throw new Error(`Several Cline logins saved (${saved}) — run /freeflow cline logout <slot>`);
  }
  if (!removeAccount(slot)) throw new Error(`Cline slot '${slot}' not found`);
  return { removed: slot, count: loadPool().accounts.length };
}

export function clineSignout(): { message: string } {
  const saved = loadPool().accounts.length;
  return {
    message: `Sign out of Cline in your browser to use a different account:\n${CLINE_BROWSER_SIGNOUT_URL}\nA private window works too, and keeps your current session.\nThen run /freeflow cline login again — each login gets its own slot (${saved ? `you have ${saved}; next is ` : "next is "}${nextClineSlot(loadPool())}).`,
  };
}

export function clineSaveKey(
  slotArg?: string,
  rawToken?: string,
): { slot: string; redacted: string; count: number; message: string } {
  const slot = (slotArg || "").trim() || nextClineSlot(loadPool());
  const token = (rawToken || "").trim();
  if (!token) throw new Error("Cancelled — no API key provided");
  const pool = addAccount(slot, token);
  return { slot, redacted: redactedToken(token), count: pool.accounts.length, message: savedMessage(slot, token) };
}

export async function clineLogin(
  slotArg?: string,
  onProgress: ClineProgress = () => {},
): Promise<{ slot: string; redacted: string; email?: string; count: number; lines: string[]; message: string }> {
  const slot = (slotArg || "").trim() || nextClineSlot(loadPool());
  let started;
  try {
    started = await startDeviceAuth();
  } catch (e) {
    if (isCertError(e)) {
      throw new Error("Could not reach Cline: your antivirus or network proxy intercepts TLS and Node does not trust it. The login retries with your OS certificates automatically — if this persists, restart the host with NODE_USE_SYSTEM_CA=1 set, or point NODE_EXTRA_CA_CERTS at your proxy CA file.");
    }
    throw new Error(`Could not reach Cline to start login: ${clineErrorMessage(e)}`);
  }
  const link = started.verificationUriComplete ?? started.verificationUri;
  const minutes = Math.max(1, Math.round(started.expiresIn / 60));
  onProgress(formatLoginLine(slot, link, started.userCode, minutes));
  try {
    const deviceTokens = await pollDeviceToken(undefined, started.deviceCode, started.interval, {
      maxWaitMs: Math.max(60_000, started.expiresIn * 1000),
    });
    const creds = await registerClineToken(undefined, deviceTokens.accessToken, deviceTokens.refreshToken);
    const apiKey = toApiKey(creds.access);
    const dup = findClineAccountSlot(
      loadPool(),
      { token: apiKey, accountId: creds.accountId, email: creds.email },
      slot,
    );
    if (dup) {
      throw new Error(
        `That Cline account${creds.email ? ` (${creds.email})` : ""} is already saved as [${dup}] — nothing added.\nUse a different account: /freeflow cline signout shows the sign-out link. Or drop the existing one first: /freeflow cline logout ${dup}`,
      );
    }
    addAccount(slot, apiKey, {
      refreshToken: creds.refresh,
      expiresAt: creds.expires,
      ...(creds.accountId ? { accountId: creds.accountId } : {}),
      ...(creds.email ? { email: creds.email } : {}),
    });
    const pool = loadPool();
    return {
      slot,
      redacted: redactedToken(apiKey),
      ...(creds.email ? { email: creds.email } : {}),
      count: pool.accounts.length,
      lines: formatClineAccountLines(pool),
      message: savedMessage(slot, apiKey),
    };
  } catch (e) {
    // The duplicate-account refusal above is already user-facing; pass it through.
    if (e instanceof Error && e.message.startsWith("That Cline account")) throw e;
    let code: string | undefined;
    if (e && typeof e === "object" && "errorCode" in e && typeof (e as { errorCode?: unknown }).errorCode === "string") {
      code = (e as { errorCode: string }).errorCode;
    }
    if (code === "access_denied") throw new Error("Cline login cancelled.");
    if (code === "expired_token") {
      throw new Error("Cline login code expired — run /freeflow cline login again for a fresh code.");
    }
    throw new Error(`Cline login did not finish: ${clineErrorMessage(e)}`);
  }
}

export async function runCline(
  request: ClineRequest,
  onProgress: ClineProgress = () => {},
): Promise<Record<string, unknown>> {
  const op = String(request.op || "").toLowerCase();
  if (op === "accounts" || op === "list") {
    const { count, lines } = clineAccounts();
    return { count, lines };
  }
  if (op === "logout" || op === "remove") return clineLogout(request.slot);
  if (op === "signout" || op === "sign-out" || op === "switch") return clineSignout();
  if (op === "save-key") return clineSaveKey(request.slot, request.token);
  if (op === "login") return clineLogin(request.slot, onProgress);
  throw new Error(CLINE_USAGE);
}
