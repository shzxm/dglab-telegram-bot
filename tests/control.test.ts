import { describe, expect, it } from "vitest";
import { MockDevice } from "../src/device.js";
import { ControlSession } from "../src/control.js";
import { encodeStrengthFrame, encodeWaveFrame } from "../src/coyote-v2.js";
import { callbackData, parseCallbackData } from "../src/bot-security.js";
import { loadConfig } from "../src/config.js";
import { createInviteCode, inviteCodeMatches, normalizeInviteCode } from "../src/session-access.js";
import { startObsOverlay } from "../src/obs-overlay.js";
import { once } from "node:events";

function make(mode: "collaboration" | "voting") {
  const device = new MockDevice();
  const now = 1_000_000;
  const session = new ControlSession({ id: "s1", chatId: 1, ownerUserId: 1, mode, limitA: 2, limitB: 2, durationMs: 60_000, startedAt: now, expiresAt: now + 60_000 }, device, 200, 2, 0, 5_000, () => now);
  return { device, session };
}

describe("ControlSession", () => {
  it("encodes official V2 little-endian frames", () => {
    expect(encodeWaveFrame(1, 9, 0).toString("hex")).toBe("210100");
    expect(encodeStrengthFrame(0, 0).toString("hex")).toBe("000000");
    expect(encodeStrengthFrame(1, 0).toString("hex")).toBe("000800");
  });
  it("rejects placeholder or malformed runtime credentials", () => {
    expect(() => loadConfig({ TG_BOT_TOKEN: "replace-with-a-new-token", TG_OWNER_USER_ID: "1", TG_ALLOWED_CHAT_ID: "-2" })).toThrow("TG_BOT_TOKEN");
    expect(loadConfig({ TG_BOT_TOKEN: "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh", TG_OWNER_USER_ID: "1", TG_ALLOWED_CHAT_ID: "-2", DG_DEVICE_MODE: "mock" }).deviceMode).toBe("mock");
  });
  it("rejects callbacks from an old or malformed session", () => {
    const current = "01234567-89ab-cdef-0123-456789abcdef";
    const old = "fedcba98-7654-3210-fedc-ba9876543210";
    const data = callbackData(current, "a_up");
    expect(parseCallbackData(data, current)).toBe("a_up");
    expect(parseCallbackData(data, old)).toBeNull();
    expect(parseCallbackData("a_up", current)).toBeNull();
  });
  it("creates a reusable normalized invite code", () => {
    const code = createInviteCode();
    expect(code).toMatch(/^[A-Z2-9]{8}$/);
    expect(inviteCodeMatches(code, code)).toBe(true);
    expect(inviteCodeMatches(code, code.toLowerCase())).toBe(true);
    expect(inviteCodeMatches(code, "WRONG123")).toBe(false);
    expect(normalizeInviteCode(` ${code} `)).toBe(code);
  });
  it("serves OBS overlay state on localhost", async () => {
    const server = startObsOverlay("127.0.0.1", 0, () => ({ active: true, mode: "活动/直播", participants: 12, strengthA: 3, strengthB: 5, waveformA: "波浪", waveformB: "按揉", votes: ["A +1=2票"], roundRemainingSeconds: 4, temporaryOperator: "测试员", operatorRemainingSeconds: 8, queueLength: 2 }));
    if (!server.listening) await once(server, "listening");
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("OBS test server did not bind TCP");
    const state = await fetch(`http://127.0.0.1:${address.port}/state`).then((response) => response.json()) as { participants: number };
    expect(state.participants).toBe(12);
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  });
  it("limits collaborative changes to one-step and the session cap", async () => {
    const { device, session } = make("collaboration");
    await session.arm();
    session.addParticipant(10, "操作员甲");
    await session.submit(10, { type: "strength_delta", channel: "A", delta: 1 });
    await session.submit(10, { type: "strength_delta", channel: "A", delta: 1 });
    await session.submit(10, { type: "strength_delta", channel: "A", delta: 1 });
    expect((await device.getStatus()).strengthA).toBe(2);
  });

  it("requires two distinct voters within the voting window", async () => {
    const { device, session } = make("voting");
    await session.arm();
    session.addParticipant(10, "操作员甲");
    session.addParticipant(11, "操作员乙");
    const action = { type: "strength_delta" as const, channel: "A" as const, delta: 1 as const };
    expect((await session.submit(10, action)).accepted).toBe(false);
    expect((await device.getStatus()).strengthA).toBe(0);
    await expect(session.submit(10, action)).rejects.toThrow("已经为 A 通道的强度投过票");
    expect((await session.submit(11, action)).accepted).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 5300));
    expect((await device.getStatus()).strengthA).toBe(1);
  }, 10000);

  it("prevents a participant from stopping the session", async () => {
    const { device, session } = make("collaboration");
    await session.arm();
    session.addParticipant(10, "操作员甲");
    await session.submit(10, { type: "strength_delta", channel: "A", delta: 1 });
    await expect(session.submit(10, { type: "stop" })).rejects.toThrow("只有管理员可以停止会话");
    expect((await device.getStatus()).strengthA).toBe(1);
    await session.stop();
    expect((await device.getStatus()).strengthA).toBe(0);
    expect(session.snapshot().state).toBe("stopped");
    expect(session.snapshot().operators).toEqual(["操作员甲"]);
  });

  it("lets a temporary operator act immediately in event mode", async () => {
    const device = new MockDevice();
    const session = new ControlSession({ id: "event1", chatId: -100, ownerUserId: 1, mode: "event", limitA: 10, limitB: 10, durationMs: 60_000, startedAt: 0, expiresAt: 0 }, device, 133, 2, 1000, 5000, Date.now, 3);
    await session.arm();
    session.addParticipant(20, "临时操作员");
    await session.applyTemporaryOperatorAction(20, { type: "strength_delta", channel: "A", delta: 3 });
    expect((await device.getStatus()).strengthA).toBe(3);
    expect(session.snapshot().voteCounts).toHaveLength(0);
  });

  it("starts the session clock on arm and expires safely", async () => {
    let now = 1_000_000;
    const device = new MockDevice();
    const session = new ControlSession({ id: "s2", chatId: 1, ownerUserId: 1, mode: "collaboration", limitA: 2, limitB: 2, durationMs: 1000, startedAt: 0, expiresAt: 0 }, device, 200, 2, 0, 10_000, () => now);
    await session.arm();
    expect(session.snapshot().state).toBe("active");
    now += 1001;
    expect(session.snapshot().state).toBe("stopped");
    expect((await device.getStatus()).strengthA).toBe(0);
  });

  it("enters fault and stops when a queued device action fails", async () => {
    class FailingDevice extends MockDevice {
      override async setStrength(): Promise<void> { throw new Error("simulated BLE write failure"); }
    }
    const device = new FailingDevice();
    const session = new ControlSession({ id: "s3", chatId: 1, ownerUserId: 1, mode: "collaboration", limitA: 2, limitB: 2, durationMs: 60_000, startedAt: 0, expiresAt: 0 }, device, 200, 2, 0);
    await session.arm();
    session.addParticipant(10);
    await expect(session.submit(10, { type: "strength_delta", channel: "A", delta: 1 })).rejects.toThrow("simulated BLE write failure");
    expect(session.snapshot().state).toBe("fault");
    expect((await device.getStatus()).strengthA).toBe(0);
  });
});
