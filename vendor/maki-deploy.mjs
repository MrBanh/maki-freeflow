// Credentials arrive in the child environment, never in argv or a temporary file.
const input = process.env.MAKI_FREEFLOW_DEPLOY;
delete process.env.MAKI_FREEFLOW_DEPLOY;
let token = "";
const emit = (event) => console.log(JSON.stringify(event));
const redact = (message) => token ? String(message).split(token).join("[redacted]") : String(message);
try {
 const request = JSON.parse(input || "{}");
 token = String(request.token || "").trim();
 const { deployRelay } = await import("./maki-deploy.ts");
 const result = await deployRelay(request.platform, token, request.name,
  (message) => emit({ type: "progress", message: redact(message) }));
 emit({ type: "result", ok: true, ...result });
} catch (error) {
 emit({ type: "result", ok: false, error: redact(error?.message || error) });
}
