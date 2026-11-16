import { afterAll, beforeAll, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { IOSBridgeServer } from "../src/ios-bridge.js";

const token = "local-test-only-" + "6".repeat(48);
const port = 29912;
let bridge: IOSBridgeServer;
let peers: WebSocket[] = [];
let disconnections = 0;
function ready(role: "host" | "remote", auth = token): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const client = new WebSocket(`ws://127.0.0.1:${port}`, { headers: { Authorization: `Bearer ${auth}` } });
    client.once("error", reject);
    client.once("open", () => {
      client.send(JSON.stringify({ type: "hello", role }));
      client.on("message", (message) => {
        try {
          if (JSON.parse(message.toString()).type === "ready") { peers.push(client); resolve(client); }
        } catch { /* ignore */ }
      });
    });
  });
}
function replyFor(client: WebSocket, id: string): Promise<any> {
  return new Promise((resolve) => client.on("message", (msg) => {
    try { const obj = JSON.parse(msg.toString()); if (obj.type === "ack" && obj.id === id) resolve(obj); } catch {}
  }));
}
beforeAll(async () => {
  bridge = new IOSBridgeServer(token, {
    snapshot: () => ({ active: false, mode: "collaboration", strengthA: 0, strengthB: 0, waveformA: "波浪", waveformB: "波浪", participants: 0, operators: [], inviteCode: "", groupId: null, eventPool: "all", expiresAt: 0, votes: {}, rampA: false, rampB: false,
      rampDoneA: 0, rampDoneB: 0, rampRateA: 3, rampRateB: 3, rampMaxA: 10, rampMaxB: 10 }),
    command: async (name) => ({ message: "handled " + name }),
    hostDisconnected: () => { disconnections += 1; },
    botUsername: () => "testbot",
  });
  bridge.listen("127.0.0.1", port);
  await new Promise(resolve => setTimeout(resolve, 80));
});
afterAll(() => { for (const peer of peers) peer.terminate(); bridge.close(); });

describe("iOS bridge authentication and host control", () => {
  it("rejects unknown client secret", async () => {
    await expect(ready("remote", "wrong-secret")).rejects.toThrow();
  });
  it("routes authenticated owner commands without Bot Token", async () => {
    const client = await ready("remote");
    const id = "one";
    const response = replyFor(client, id);
    client.send(JSON.stringify({ type: "command", id, command: "status", payload: {} }));
    expect(await response).toMatchObject({ ok: true, state: { message: "handled status" } });
  });
  it("host must explicitly acknowledge the device request", async () => {
    const client = await ready("host");
    client.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.type === "command" && message.command === "device.connect") {
        client.send(JSON.stringify({ type: "ack", id: message.id, ok: true, state: { connected: true, armed: true } }));
      }
    });
    expect(await bridge.hostCommand("device.connect", {}, 2000)).toMatchObject({ armed: true });
    client.terminate();
    await new Promise(resolve => setTimeout(resolve, 100));
    expect(disconnections).toBeGreaterThan(0);
  });
});
