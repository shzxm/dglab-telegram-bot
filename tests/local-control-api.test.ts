import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { LocalControlAPI } from "../src/local-control-api.js";

const token = "test-local-api-token-" + "a".repeat(48);
const port = 29918;
let api: LocalControlAPI;
const invoked: string[] = [];
async function request(path: string, init: RequestInit = {}) {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) },
  });
}
function body(command: string, payload: Record<string, unknown> = {}) {
  return JSON.stringify({ command, payload });
}
beforeAll(async () => {
  api = new LocalControlAPI(token, {
    snapshot: async () => ({ active: false, strengthA: 0, strengthB: 0, deviceMode: "mock" }),
    command: async (command, payload) => {
      invoked.push(command);
      return { message: command, payload };
    },
  });
  api.listen(port);
  await new Promise((resolve) => setTimeout(resolve, 75));
});
afterAll(() => api.close());

describe("loopback-only authenticated DG-LAB desktop API", () => {
  it("health is non-sensitive but status requires a valid bearer token", async () => {
    expect((await request("/health")).status).toBe(200);
    expect((await fetch(`http://127.0.0.1:${port}/v1/status`)).status).toBe(401);
    expect((await request("/v1/status", { headers: { Authorization: "Bearer invalid" } })).status).toBe(401);
    const status = await request("/v1/status");
    expect(status.status).toBe(200);
    expect((await status.json()).state).toMatchObject({ active: false, deviceMode: "mock", strengthA: 0 });
  });
  it("rejects browser-origin requests even if a secret is leaked to a page", async () => {
    expect((await request("/v1/status", { headers: { Origin: "https://malicious.example" } })).status).toBe(401);
    expect((await request("/v1/capabilities")).status).toBe(200);
  });
  it("requires explicit hardware/session confirmations and filters commands", async () => {
    const headers = { "Content-Type": "application/json" };
    expect((await request("/v1/command", { method: "POST", headers, body: body("session.arm") })).status).toBe(403);
    expect((await request("/v1/command", { method: "POST", headers, body: body("device.connect") })).status).toBe(403);
    expect((await request("/v1/command", { method: "POST", headers, body: body("system.exec") })).status).toBe(400);
    expect((await request("/v1/command", { method: "POST", headers: { ...headers, "X-DGLab-Confirm": "arm" }, body: body("session.arm") })).status).toBe(200);
    expect(invoked).toContain("session.arm");
    expect(invoked).not.toContain("system.exec");
  });
  it("does not accept malformed or huge command envelopes", async () => {
    const headers = { "Content-Type": "application/json" };
    expect((await request("/v1/command", { method: "POST", headers, body: "{" })).status).toBe(400);
    expect((await request("/v1/command", { method: "POST", headers, body: body("status", [] as unknown as Record<string, unknown>) })).status).toBe(400);
    expect((await request("/v1/command", { method: "POST", headers, body: body("status", { filler: "x".repeat(20_000) }) })).status).toBe(413);
    expect((await request("/v1/command", { method: "POST", body: body("status") })).status).toBe(415);
  });
  it("emergency stop remains available independent of command throttling", async () => {
    const headers = { "Content-Type": "application/json" };
    const stop = await request("/v1/command", { method: "POST", headers, body: body("session.stop") });
    expect(stop.status).toBe(200);
    expect((await stop.json()).state.message).toBe("session.stop");
  });
});
