import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";

/** A separate, LOOPBACK-ONLY control plane for native macOS UI and CLI integrations. */
export const LOCAL_API_COMMANDS = [
  "status", "device.status", "device.connect", "session.create", "session.arm", "session.stop",
  "session.disconnect", "session.invite", "session.join", "owner.delta", "owner.waveform",
  "ramp.rate", "ramp.maxIncrease", "ramp.toggle", "audio.volume", "audio.beat",
  "audio.off", "audio.target", "audio.range", "group.bind", "vote.submit",
  "event.queue", "event.queue.leave", "event.random", "event.pool",
] as const;

export interface ControlAPIHandlers {
  snapshot: () => Promise<Record<string, unknown>>;
  command: (command: string, payload: Record<string, unknown>) => Promise<Record<string, unknown>>;
}

const allowed = new Set<string>(LOCAL_API_COMMANDS);
const MAX_PAYLOAD = 16_384;

export class LocalControlAPI {
  private readonly recent: number[] = [];
  private readonly server = createServer((req, res) => { void this.handle(req, res); });
  constructor(private readonly token: string, private readonly callbacks: ControlAPIHandlers) {
    if (token.length < 32) throw new Error("Control API secret must contain at least 32 characters");
  }
  listen(port = 8789): void {
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid control API port");
    this.server.on("error", (error) => console.error("DG-LAB local API:", error));
    this.server.listen(port, "127.0.0.1");
    console.log(`DG-LAB local API listening on http://127.0.0.1:${port} (Bearer required)`);
  }
  close(): void { this.server.close(); }

  private reply(res: ServerResponse, code: number, value: Record<string, unknown>): void {
    if (res.writableEnded) return;
    res.writeHead(code, {
      "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    });
    res.end(JSON.stringify(value));
  }
  private authenticate(req: IncomingMessage): boolean {
    const provided = req.headers.authorization?.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
    const actual = Buffer.from(provided, "utf8"), expected = Buffer.from(this.token, "utf8");
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  }
  private limited(command: string): boolean {
    if (command === "session.stop" || command === "session.disconnect") return false;
    const now = Date.now();
    while (this.recent.length && now - this.recent[0]! >= 1000) this.recent.shift();
    if (this.recent.length >= 6) return true;
    this.recent.push(now);
    return false;
  }
  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    try {
      if (req.socket.remoteAddress !== "127.0.0.1" && req.socket.remoteAddress !== "::1") {
        this.reply(res, 403, { ok: false, error: "Loopback access only" }); return;
      }
      if (req.method === "GET" && req.url === "/health") {
        this.reply(res, 200, { ok: true, api: "dglab-local", version: 1 }); return;
      }
      // Browsers and cross-origin form requests must not be able to operate the device.
      if (req.headers.origin || !this.authenticate(req)) {
        this.reply(res, 401, { ok: false, error: "Bearer authentication required" }); return;
      }
      if (req.method === "GET" && req.url === "/v1/status") {
        this.reply(res, 200, { ok: true, state: await this.callbacks.snapshot() }); return;
      }
      if (req.method === "GET" && req.url === "/v1/capabilities") {
        this.reply(res, 200, { ok: true, commands: LOCAL_API_COMMANDS,
          strengthDeltas: [-5, -3, -1, 1, 3, 5], channels: ["A", "B"],
          waveforms: ["imported_0", "imported_1", "imported_2", "imported_3", "imported_4", "imported_5", "soft", "rhythm", "rise"],
          ramp: { minSeconds: 1, maxSeconds: 60, minIncrease: 1, maxIncrease: 33 },
          audio: { minHz: 1, maxHz: 100, targets: ["A", "B", "both"] },
        }); return;
      }
      if (req.method === "POST" && req.url === "/v1/command") {
        if (!/^application\/json(?:\s*;|$)/i.test(req.headers["content-type"] ?? "")) {
          this.reply(res, 415, { ok: false, error: "Expected application/json" }); return;
        }
        let raw = "";
        for await (const chunk of req) {
          raw += (chunk as Buffer).toString("utf8");
          if (Buffer.byteLength(raw) > MAX_PAYLOAD) {
            this.reply(res, 413, { ok: false, error: "Request too large" }); return;
          }
        }
        let body: unknown;
        try { body = JSON.parse(raw); }
        catch { this.reply(res, 400, { ok: false, error: "Invalid JSON" }); return; }
        if (!body || typeof body !== "object" || Array.isArray(body)) {
          this.reply(res, 400, { ok: false, error: "Invalid command envelope" }); return;
        }
        const value = body as { command?: unknown; payload?: unknown };
        if (typeof value.command !== "string" || !allowed.has(value.command)) {
          this.reply(res, 400, { ok: false, error: "Unknown command" }); return;
        }
        const payload = value.payload ?? {};
        if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
          this.reply(res, 400, { ok: false, error: "Invalid payload" }); return;
        }
        if (value.command === "session.arm" && req.headers["x-dglab-confirm"] !== "arm") {
          this.reply(res, 403, { ok: false, error: "Explicit arm confirmation required" }); return;
        }
        if (value.command === "device.connect" && req.headers["x-dglab-confirm"] !== "connect") {
          this.reply(res, 403, { ok: false, error: "Explicit device confirmation required" }); return;
        }
        if (this.limited(value.command)) {
          this.reply(res, 429, { ok: false, error: "Too many control commands" }); return;
        }
        try {
          const state = await this.callbacks.command(value.command, payload as Record<string, unknown>);
          this.reply(res, 200, { ok: true, state });
        } catch (error) {
          this.reply(res, 409, { ok: false, error: error instanceof Error ? error.message : "Command rejected" });
        }
        return;
      }
      this.reply(res, 404, { ok: false, error: "Not found" });
    } catch (error) {
      this.reply(res, 500, { ok: false, error: error instanceof Error ? error.message : "Server error" });
    }
  }
}
