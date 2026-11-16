import { describe, expect, it, vi } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { AutoRampController } from "../src/auto-ramp.js";
import { AudioFeatureMapper, SystemAudioReactiveController, validateFrequencyRange } from "../src/audio-reactive.js";
import { MockDevice } from "../src/device.js";
import { ControlSession } from "../src/control.js";

const range = { minHz: 5, maxHz: 20 };

describe("safe system audio feature mapping", () => {
  it("validates V2 1-100 Hz cycles without confusing Hz and milliseconds", () => {
    expect(validateFrequencyRange({ minHz: 1, maxHz: 100 })).toEqual({ minHz: 1, maxHz: 100 });
    expect(() => validateFrequencyRange({ minHz: 0, maxHz: 100 })).toThrow();
    expect(() => validateFrequencyRange({ minHz: 10, maxHz: 101 })).toThrow();
    expect(() => validateFrequencyRange({ minHz: 30, maxHz: 20 })).toThrow();
    expect(validateFrequencyRange({ minHz: 20, maxHz: 20 })).toEqual({ minHz: 20, maxHz: 20 });
  });

  it("stays at quarter speed when silence is valid, without an off command", () => {
    const mapper = new AudioFeatureMapper();
    for (let i = 0; i < 10; i++) {
      expect(mapper.update(0, i * 100, "volume", range)).toEqual({ speedFactor: 0.25 });
    }
    for (let i = 0; i < 6; i++) mapper.update(0.18, 1000 + i * 100, "volume", range);
    expect(mapper.update(0.18, 1600, "volume", range)).toEqual({ speedFactor: 1 });
    for (let i = 0; i < 20; i++) mapper.update(0, 1700 + i * 100, "volume", range);
    expect(mapper.update(0, 3900, "volume", range)).toEqual({ speedFactor: 0.25 });
  });

  it("translates an onset to selected higher frequency (shorter period) and decays to low end", () => {
    const mapper = new AudioFeatureMapper();
    expect(mapper.update(0.0, 0, "beat", range)).toEqual({ periodMs: 200 });
    expect(mapper.update(0.25, 200, "beat", range)).toEqual({ periodMs: 50 });
    expect(mapper.update(0.23, 300, "beat", range)).toEqual({ periodMs: 50 });
    expect(mapper.update(0.0, 600, "beat", range)).toEqual({ periodMs: 200 });
  });

  it("fixed-frequency presets do not change the waveform period on a beat", () => {
    for (const hz of [1, 20, 50, 100]) {
      const mapper = new AudioFeatureMapper();
      const fixed = { minHz: hz, maxHz: hz };
      const expectedPeriod = Math.round(1000 / hz);
      expect(mapper.update(0, 0, "beat", fixed)).toEqual({ periodMs: expectedPeriod });
      expect(mapper.update(0.25, 400, "beat", fixed)).toEqual({ periodMs: expectedPeriod });
      expect(mapper.update(0, 800, "beat", fixed)).toEqual({ periodMs: expectedPeriod });
    }
  });

  it("combines loudness playback speed with beat period without changing strength", () => {
    const mapper = new AudioFeatureMapper();
    const quiet = mapper.update(0, 0, "both", range);
    expect(quiet).toEqual({ speedFactor: 0.25, periodMs: 200 });
    const onset = mapper.update(0.25, 200, "both", range);
    expect(onset).toEqual({ speedFactor: 1, periodMs: 50 });
    const fixed = mapper.update(0.25, 400, "both", { minHz: 50, maxHz: 50 });
    expect(fixed).toEqual({ speedFactor: 1, periodMs: 20 });
  });

  it("independently toggles both sound controls while A/B auto-ramp remains active", async () => {
    const folder = mkdtempSync(join(tmpdir(), "dglab-audio-mock-"));
    const helper = join(folder, "meter.js");
    writeFileSync(helper, `#!/usr/bin/env node
setInterval(() => process.stdout.write(JSON.stringify({ rms: 0.25 }) + "\\n"), 55);
`, { mode: 0o700 });
    const device = new MockDevice();
    const session = new ControlSession({ id: "independent", chatId: 1, ownerUserId: 1, mode: "collaboration", limitA: 10, limitB: 10, durationMs: 60_000, startedAt: 0, expiresAt: 0 }, device);
    const sound = new SystemAudioReactiveController(device, helper);
    const ramps = new AutoRampController();
    let error: string | null = null;
    try {
      await session.arm();
      ramps.start(session, "A", 1);
      ramps.start(session, "B", 1);
      sound.toggleMode(session, "volume", "both", range, (reason) => { error = reason; });
      expect(sound.mode).toBe("volume");
      sound.toggleMode(session, "beat", "both", range, (reason) => { error = reason; });
      expect(sound.mode).toBe("both");
      // The spawned audio helper may start later on busy CI machines. Wait for
      // observable RMS output instead of assuming a fixed startup duration.
      await vi.waitFor(() => {
        expect(device.modulations.A?.speedFactor).toBe(1);
        expect(device.modulations.B?.speedFactor).toBe(1);
      }, { timeout: 5_000, interval: 100 });
      await vi.waitFor(async () => {
        expect((await device.getStatus()).strengthA).toBeGreaterThan(0);
      }, { timeout: 5_000, interval: 100 });
      expect(sound.isEnabled("volume")).toBe(true);
      expect(sound.isEnabled("beat")).toBe(true);
      expect(device.modulations.A?.speedFactor).toBe(1);
      expect([50, 200]).toContain(device.modulations.A?.periodMs);
      expect(device.modulations.B?.speedFactor).toBe(1);
      expect(ramps.isEnabled("A")).toBe(true);
      expect(ramps.isEnabled("B")).toBe(true);
      expect((await device.getStatus()).strengthA).toBeGreaterThan(0);
      sound.toggleMode(session, "volume", "both", range, (reason) => { error = reason; });
      expect(sound.mode).toBe("beat");
      expect(ramps.isEnabled("A")).toBe(true);
      await vi.waitFor(() => {
        expect([50, 200]).toContain(device.modulations.A?.periodMs);
        expect(device.modulations.A?.speedFactor).toBeUndefined();
      }, { timeout: 3_000, interval: 100 });
      sound.toggleMode(session, "beat", "both", range, (reason) => { error = reason; });
      expect(sound.mode).toBe("off");
      expect(device.modulations.A).toBeUndefined();
      expect(ramps.isEnabled("A")).toBe(true);
      expect(error).toBeNull();
    } finally {
      sound.stop();
      ramps.stop();
      await session.stop();
      rmSync(folder, { recursive: true, force: true });
    }
  });

  it("modulates only wave characteristics; never adjusts mock device strength", async () => {
    const device = new MockDevice();
    const session = new ControlSession({ id: "safe", chatId: 1, ownerUserId: 1, mode: "collaboration", limitA: 2, limitB: 2, durationMs: 60_000, startedAt: 0, expiresAt: 0 }, device);
    await session.arm();
    device.setWaveformModulation("A", { speedFactor: 0.25 });
    device.setWaveformModulation("B", { periodMs: 50 });
    expect((await device.getStatus()).strengthA).toBe(0);
    expect((await device.getStatus()).strengthB).toBe(0);
    expect(device.events.filter((event) => event.type === "setStrength")).toHaveLength(0);
    await session.stop();
    expect(device.modulations.A).toBeUndefined();
    expect(device.modulations.B).toBeUndefined();
  });
});
