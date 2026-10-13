// Job entry for /freeflow cline. The login token, if any, arrives in the
// child environment — never in argv, a temporary file, or job output.
const input = process.env.MAKI_FREEFLOW_CLINE;
delete process.env.MAKI_FREEFLOW_CLINE;
let token = "";
const emit = (event) => console.log(JSON.stringify(event));
const redact = (message) => token ? String(message).split(token).join("[redacted]") : String(message);
try {
  const request = JSON.parse(input || "{}");
  token = String(request.token || "").trim();
  const { runCline } = await import("./maki-cline.ts");
  const result = await runCline(request, (message) => emit({ type: "progress", message: redact(message) }));
  emit({ type: "result", ok: true, ...result });
} catch (error) {
  emit({ type: "result", ok: false, error: redact(error?.message || error) });
}
