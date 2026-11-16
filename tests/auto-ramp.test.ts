import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AutoRampController } from "../src/auto-ramp.js";
import { ControlSession } from "../src/control.js";
import { MockDevice } from "../src/device.js";

function make(limit = 50) {
  const device = new MockDevice();
  const session = new ControlSession({
    id: "ramp-test", chatId: 1, ownerUserId: 1, mode: "collaboration",
    limitA: limit, limitB: limit, durationMs: 600_000, startedAt: 0, expiresAt: 0,
  }, device);
  const ramp = new AutoRampController();
  return { device, session, ramp };
}

describe("AutoRampController: independent A/B channels", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("keeps A enabled beyond 30 seconds without changing B", async () => {
    const { device, session, ramp } = make();
    await session.arm();
    ramp.start(session, "A", 3);
    await vi.advanceTimersByTimeAsync(33_000);
    expect(ramp.isEnabled("A")).toBe(true);
    expect(ramp.isEnabled("B")).toBe(false);
    expect((await device.getStatus()).strengthA).toBe(11);
    expect((await device.getStatus()).strengthB).toBe(0);
    ramp.stop("A");
    await vi.advanceTimersByTimeAsync(30_000);
    expect((await device.getStatus()).strengthA).toBe(11);
    await session.stop();
  });

  it("runs A/B on distinct intervals and stopping A leaves B running", async () => {
    const { device, session, ramp } = make();
    await session.arm();
    ramp.start(session, "A", 3);
    ramp.start(session, "B", 5);
    await vi.advanceTimersByTimeAsync(15_000);
    expect((await device.getStatus()).strengthA).toBe(5);
    expect((await device.getStatus()).strengthB).toBe(3);
    ramp.stop("A");
    await vi.advanceTimersByTimeAsync(10_000);
    expect((await device.getStatus()).strengthA).toBe(5);
    expect((await device.getStatus()).strengthB).toBe(5);
    expect(ramp.isEnabled("B")).toBe(true);
    ramp.stop();
    await session.stop();
  });

  it("changing A frequency does not reset B schedule", async () => {
    const { device, session, ramp } = make();
    await session.arm();
    ramp.start(session, "A", 3);
    ramp.start(session, "B", 5);
    await vi.advanceTimersByTimeAsync(3_000);
    ramp.start(session, "A", 7);
    await vi.advanceTimersByTimeAsync(2_000);
    expect((await device.getStatus()).strengthA).toBe(1);
    expect((await device.getStatus()).strengthB).toBe(1);
    await vi.advanceTimersByTimeAsync(5_000);
    expect((await device.getStatus()).strengthA).toBe(2);
    expect((await device.getStatus()).strengthB).toBe(2);
    ramp.stop();
    await session.stop();
  });

  it("does not write above strength cap", async () => {
    const { device, session, ramp } = make(2);
    await session.arm();
    ramp.start(session, "A", 3);
    ramp.start(session, "B", 5);
    await vi.advanceTimersByTimeAsync(45_000);
    expect((await device.getStatus()).strengthA).toBe(2);
    expect((await device.getStatus()).strengthB).toBe(2);
    expect(device.events.filter(e => e.type === "setStrength")).toHaveLength(4);
    ramp.stop();
    await session.stop();
  });

  it("stops after exactly N successful automatic +1 steps", async () => {
    const { device, session, ramp } = make(100);
    await session.arm();
    ramp.start(session, "A", 1, 5);
    await vi.advanceTimersByTimeAsync(15_000);
    expect(ramp.completed("A")).toBe(5);
    expect(ramp.maximum("A")).toBe(5);
    expect(ramp.isEnabled("A")).toBe(false);
    expect((await device.getStatus()).strengthA).toBe(5);
    await session.stop();
  });

  it("changing interval preserves completed count and automatically stops", async () => {
    const { device, session, ramp } = make(100);
    await session.arm();
    ramp.start(session, "A", 2, 4);
    await vi.advanceTimersByTimeAsync(4_000);
    expect(ramp.completed("A")).toBe(2);
    ramp.updateRate("A", 1);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(ramp.completed("A")).toBe(4);
    expect(ramp.isEnabled("A")).toBe(false);
    expect((await device.getStatus()).strengthA).toBe(4);
    await session.stop();
  });

  it("reducing maximum during a running ramp stops without extra writes", async () => {
    const { device, session, ramp } = make(100);
    await session.arm();
    ramp.start(session, "B", 1, 33);
    await vi.advanceTimersByTimeAsync(3_000);
    expect(ramp.completed("B")).toBe(3);
    ramp.updateMaximum("B", 2);
    await vi.advanceTimersByTimeAsync(8_000);
    expect(ramp.isEnabled("B")).toBe(false);
    expect((await device.getStatus()).strengthB).toBe(3);
    await session.stop();
  });

  it("stops as soon as the channel's independent cap is reached", async () => {
    const { device, session, ramp } = make(2);
    await session.arm();
    ramp.start(session, "A", 1, 33);
    await vi.advanceTimersByTimeAsync(6_000);
    expect(ramp.isEnabled("A")).toBe(false);
    expect(ramp.completed("A")).toBe(2);
    expect((await device.getStatus()).strengthA).toBe(2);
    await session.stop();
  });

  it("rejects invalid time intervals and step limits", async () => {
    const { session, ramp } = make();
    await session.arm();
    expect(() => ramp.start(session, "A", 0, 3)).toThrow();
    expect(() => ramp.start(session, "A", 61, 3)).toThrow();
    expect(() => ramp.start(session, "A", 1.5, 3)).toThrow();
    expect(() => ramp.start(session, "A", 1, 0)).toThrow();
    expect(() => ramp.start(session, "A", 1, 34)).toThrow();
    await session.stop();
  });

  it("stops both when the session stops", async () => {
    const { device, session, ramp } = make();
    await session.arm();
    ramp.start(session, "A", 3);
    ramp.start(session, "B", 5);
    await vi.advanceTimersByTimeAsync(5_000);
    await session.stop();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(ramp.isEnabled("A")).toBe(false);
    expect(ramp.isEnabled("B")).toBe(false);
    expect((await device.getStatus()).strengthA).toBe(0);
    expect((await device.getStatus()).strengthB).toBe(0);
  });
});
