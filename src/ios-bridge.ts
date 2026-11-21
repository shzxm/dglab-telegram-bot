import { createServer, type IncomingMessage } from "node:http";
import { timingSafeEqual, randomUUID } from "node:crypto";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { homedir } from "node:os";
import { join } from "node:path";
import { WebSocketServer, type WebSocket } from "ws";

export interface IOSBridgeSnapshot {
  active: boolean;
  mode: string;
  strengthA: number;
  strengthB: number;
  waveformA: string;
  waveformB: string;
  participants: number;
  operators: string[];
  inviteCode: string;
  groupId: number | null;
  eventPool: string;
  expiresAt: number;
  votes: Record<string, number>;
  rampA: boolean;
  rampB: boolean;
  rampDoneA: number;
  rampDoneB: number;
  rampRateA: number;
  rampRateB: number;
  rampMaxA: number;
  rampMaxB: number;
}
export interface IOSBridgeCallbacks {
  snapshot: () => IOSBridgeSnapshot;
  command: (name: string, payload: Record<string, unknown>) => Promise<Record<string, unknown>>;
  hostDisconnected: () => void;
  botUsername: () => string;
}
interface PendingCall { resolve: (value: Record<string, unknown>) => void; reject: (reason: Error) => void; timer: ReturnType<typeof setTimeout> }
interface Message { type?: string; id?: string; role?: string; command?: string; payload?: Record<string, unknown>; ok?: boolean; state?: Record<string, unknown>; error?: string }

/**
 * Dedicated high-entropy bridge secret, never the Telegram Bot token.
 * Explicit host consent is enforced again on the iPhone before Bluetooth is armed.
 * One BLE host and multiple read/control clients. No public bind by default.
 */
export class IOSBridgeServer {
  private host: WebSocket | null = null;
  private readonly clients = new Set<WebSocket>();
  private readonly pending = new Map<string, PendingCall>();
  private readonly server = createServer((request, response) => {
    if (request.url === "/health") {
      response.setHeader("Content-Type", "application/json");
      response.setHeader("Cache-Control", "no-store");
      response.end(JSON.stringify({ ok: true, pairedHost: this.host?.readyState === 1 }));
    } else { response.writeHead(404); response.end(); }
  });
  private readonly ws = new WebSocketServer({ noServer: true, maxPayload: 32_768, perMessageDeflate: false });
  private timer: ReturnType<typeof setInterval> | null = null;
  private audio: ChildProcessByStdio<null, Readable, Readable> | null = null;
  private audioBuffer = "";

  constructor(private readonly token: string, private readonly handlers: IOSBridgeCallbacks) {
    if (token.length < 32) throw new Error("IOS_BRIDGE_TOKEN must have >=32 random characters");
    this.server.on("upgrade", (request, socket, head) => {
      const presented = request.headers.authorization?.replace(/^Bearer /i, "") ?? "";
      const expected = Buffer.from(token, "utf8"), actual = Buffer.from(presented, "utf8");
      if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"); socket.destroy(); return;
      }
      this.ws.handleUpgrade(request, socket, head, (client) => this.accept(client));
    });
  }
  listen(host: string, port: number): void {
    this.server.listen(port, host);
    this.server.on("error", (e) => console.error("iOS bridge listener:", e));
    this.timer = setInterval(() => this.broadcastState(), 900);
    this.timer.unref?.();
    console.log(`DG-LAB iOS Bridge listening on ${host}:${port} (separate token; no secrets logged)`);
  }
  get hostConnected(): boolean { return this.host?.readyState === 1; }
  private accept(client: WebSocket): void {
    let role: "host" | "remote" | null = null;
    let recentCommands: number[] = [];
    this.clients.add(client);
    client.on("message", (wire, isBinary) => {
      if (isBinary) { client.close(1003, "JSON only"); return; }
      let message: Message;
      try { message = JSON.parse(wire.toString()) as Message; }
      catch { client.close(1007, "Invalid JSON"); return; }
      if (message.type === "hello") {
        if (message.role !== "host" && message.role !== "remote") { client.close(1008, "Invalid role"); return; }
        role = message.role;
        if (role === "host") {
          if (this.hostConnected && this.host !== client) { client.close(1008, "Host already paired"); return; }
          this.host = client;
        }
        this.send(client, { type: "ready", role, botUsername: this.handlers.botUsername() });
        this.send(client, { type: "snapshot", state: this.handlers.snapshot() });
        return;
      }
      if (!role) { client.close(1008, "Handshake required"); return; }
      if (message.type === "ack" && role === "host" && client === this.host && message.id) {
        const pending = this.pending.get(message.id);
        if (pending) {
          clearTimeout(pending.timer); this.pending.delete(message.id);
          if (message.ok === true) pending.resolve(message.state ?? {});
          else pending.reject(new Error(message.error ?? "iPhone rejected device command"));
        }
      }
      if (message.type === "command" && role === "remote" && message.id && message.command) {
        // Owner bridge actions bypass Telegram's message-rate middleware, so impose
        // an independent limit here (stop/disconnect remain immediately available).
        if (message.command !== "session.stop" && message.command !== "session.disconnect") {
          const now = Date.now();
          recentCommands = recentCommands.filter(t => now - t < 1000);
          if (recentCommands.length >= 3) {
            this.send(client, { type: "ack", id: message.id, ok: false, error: "Too many bridge actions; try again" });
            return;
          }
          recentCommands.push(now);
        }
        void Promise.resolve().then(() => this.handlers.command(message.command!, message.payload ?? {}))
          .then((result) => this.send(client, { type: "ack", id: message.id, ok: true, state: result }))
          .catch((err: unknown) => this.send(client, { type: "ack", id: message.id, ok: false, error: err instanceof Error ? err.message : "Operation rejected" }));
      }
      if (message.type === "command" && role === "host" && message.command === "host.stopped") {
        this.handlers.hostDisconnected();
        this.send(client, { type: "ack", id: message.id, ok: true, state: { stopped: true } });
      }
      if (message.type === "command" && role === "host" && message.command === "audio.monitor.start") {
        this.startAudioMonitor(); this.send(client, { type: "ack", id: message.id, ok: true, state: { started: true } });
      }
      if (message.type === "command" && role === "host" && message.command === "audio.monitor.stop") {
        this.stopAudioMonitor(); this.send(client, { type: "ack", id: message.id, ok: true, state: { stopped: true } });
      }
    });
    client.on("close", () => {
      this.clients.delete(client);
      if (this.host === client) {
        this.host = null;
        this.stopAudioMonitor();
        for (const [id, request] of this.pending) {
          clearTimeout(request.timer); request.reject(new Error("iPhone host disconnected")); this.pending.delete(id);
        }
        this.handlers.hostDisconnected();
      }
    });
    client.on("error", (e) => { console.error("iOS bridge peer error:", e.message); client.terminate(); });
  }
  async hostCommand(command: string, payload: Record<string, unknown> = {}, timeoutMs = 8_000): Promise<Record<string, unknown>> {
    if (!this.hostConnected) throw new Error("iPhone has not paired as BLE host");
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("Timed out awaiting local iPhone BLE host acknowledgement"));
      }, Math.min(70_000, timeoutMs));
      this.pending.set(id, { resolve, reject, timer });
      this.send(this.host!, { type: "command", id, command, payload });
    });
  }
  private broadcastState(): void {
    if (!this.clients.size) return;
    const packet = { type: "snapshot", state: this.handlers.snapshot() };
    for (const client of this.clients) if (client.readyState === 1) this.send(client, packet);
  }
  private send(client: WebSocket, obj: Record<string, unknown>): void {
    if (client.readyState !== 1) return;
    try { client.send(JSON.stringify(obj)); } catch { client.terminate(); }
  }
  private startAudioMonitor(): void {
    if (this.audio) return;
    // Standalone macOS App bundles its own helper; the old ~/.local/bin path
    // exists only for the separately deployed LaunchAgent controller.
    const exe = process.env.DGLAB_AUDIO_HELPER_PATH ?? join(homedir(), ".local", "bin", "dglab-system-audio-meter");
    const child = spawn(exe, [], { stdio: ["ignore", "pipe", "pipe"] });
    this.audio = child; this.audioBuffer = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      this.audioBuffer += chunk;
      if (this.audioBuffer.length > 16384) { this.stopAudioMonitor(); return; }
      let at = this.audioBuffer.indexOf("\n");
      while (at >= 0) {
        const line = this.audioBuffer.slice(0, at);
        this.audioBuffer = this.audioBuffer.slice(at + 1);
        try {
          const parsed = JSON.parse(line) as { rms?: number };
          if (typeof parsed.rms === "number" && Number.isFinite(parsed.rms) && parsed.rms >= 0 && parsed.rms <= 1 && this.hostConnected) {
            this.send(this.host!, { type: "audio.metric", rms: parsed.rms });
          }
        } catch { /* ignore malformed RMS lines */ }
        at = this.audioBuffer.indexOf("\n");
      }
    });
    child.stderr.on("data", (buf: Buffer) => console.error("Bridge audio helper:", buf.toString().slice(0, 180)));
    child.on("error", (e) => { console.error("Bridge audio launch failed:", e.message); this.stopAudioMonitor(); });
    child.on("exit", () => { if (this.audio === child) { this.audio = null; this.audioBuffer = ""; } });
  }
  private stopAudioMonitor(): void { this.audio?.kill("SIGTERM"); this.audio = null; this.audioBuffer = ""; }
  close(): void {
    this.stopAudioMonitor();
    if (this.timer) clearInterval(this.timer);
    for (const peer of this.clients) peer.close();
    this.ws.close(); this.server.close();
  }
}
