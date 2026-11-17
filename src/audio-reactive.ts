import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { Device, Channel, WaveformModulation } from "./device.js";
import type { ControlSession } from "./control.js";

export type AudioMode = "off" | "volume" | "beat" | "both";
export type AudioTarget = Channel | "both";
export interface FrequencyRange { minHz: number; maxHz: number }
export const AUDIO_FREQUENCY_RANGES: readonly FrequencyRange[] = [
  { minHz: 1, maxHz: 1 },
  { minHz: 20, maxHz: 20 },
  { minHz: 50, maxHz: 50 },
  { minHz: 100, maxHz: 100 },
  { minHz: 5, maxHz: 15 },
  { minHz: 10, maxHz: 30 },
  { minHz: 20, maxHz: 50 },
  { minHz: 1, maxHz: 100 },
];

export function validateFrequencyRange(range: FrequencyRange): FrequencyRange {
  if (!Number.isFinite(range.minHz) || !Number.isFinite(range.maxHz) ||
      range.minHz < 1 || range.maxHz > 100 || range.minHz > range.maxHz) {
    throw new Error("V2 频率范围必须满足 1 ≤ 最低 Hz ≤ 最高 Hz ≤ 100");
  }
  return range;
}

/** Converts raw audio loudness to waveform tempo and V2 *cycle* rate.
 * Never changes the device's voltage/strength, waveform pulse width (Z) or session limits.
 */
export class AudioFeatureMapper {
  private envelope = 0;
  private previous = 0;
  private lastBeat = -Infinity;
  private lastSpeed: 0.25 | 1 = 0.25;

  update(rms: number, timestampMs: number, mode: Exclude<AudioMode, "off">, range: FrequencyRange): WaveformModulation {
    validateFrequencyRange(range);
    if (!Number.isFinite(rms) || rms < 0 || rms > 1) throw new Error("无效音频数据");
    this.envelope = this.envelope * 0.65 + rms * 0.35;
    const modulation: WaveformModulation = {};
    if (mode === "volume" || mode === "both") {
      // An explicitly silent, valid sample keeps the selected waveform playing slower.
      if (this.lastSpeed === 0.25 && this.envelope >= 0.045) this.lastSpeed = 1;
      else if (this.lastSpeed === 1 && this.envelope <= 0.025) this.lastSpeed = 0.25;
      modulation.speedFactor = this.lastSpeed;
    }
    if (mode === "beat" || mode === "both") {
      const onset = rms - this.previous;
      const beat = range.minHz !== range.maxHz && rms > 0.055 && onset > 0.045 && timestampMs - this.lastBeat >= 250;
      if (beat) this.lastBeat = timestampMs;
      const recentBeat = timestampMs - this.lastBeat < 280;
      const hz = recentBeat ? range.maxHz : range.minHz;
      modulation.periodMs = Math.max(10, Math.min(1000, Math.round(1000 / hz)));
    }
    this.previous = rms;
    return modulation;
  }
}

export class SystemAudioReactiveController {
  private process: ChildProcessByStdio<null, Readable, Readable> | null = null;
  private reader = "";
  private guardTimer: ReturnType<typeof setInterval> | null = null;
  private mapper = new AudioFeatureMapper();
  private lastMetricAt = 0;
  private running: Exclude<AudioMode, "off"> | null = null;
  private destination: AudioTarget = "both";
  private frequencyRange: FrequencyRange = AUDIO_FREQUENCY_RANGES[0]!;
  private onFailure: (message: string) => void = () => {};
  private generation = 0;
  private lastRenderAt = 0;
  private readonly helperPath: string;

  constructor(private readonly device: Device, helperPath?: string) {
    this.helperPath = helperPath ?? process.env.DGLAB_AUDIO_HELPER_PATH ?? join(homedir(), ".local", "bin", "dglab-system-audio-meter");
  }
  get mode(): AudioMode { return this.running ?? "off"; }
  isEnabled(mode: "volume" | "beat"): boolean {
    return this.running === mode || this.running === "both";
  }
  get target(): AudioTarget { return this.destination; }
  get range(): FrequencyRange { return this.frequencyRange; }

  updateSettings(target: AudioTarget, range: FrequencyRange): void {
    this.destination = target;
    this.frequencyRange = validateFrequencyRange(range);
    for (const channel of ["A", "B"] as const) {
      if (target !== "both" && target !== channel) this.device.setWaveformModulation(channel, null);
    }
  }

  /** Independent toggles share one audio capture process; toggling either keeps the other enabled. */
  toggleMode(session: ControlSession, mode: "volume" | "beat", target: AudioTarget, range: FrequencyRange, onFailure: (message: string) => void): void {
    if (this.running === null) {
      this.start(session, mode, target, range, onFailure);
      return;
    }
    if (session.snapshot().state !== "active") throw new Error("会话尚未授权");
    this.updateSettings(target, range);
    const wasEnabled = this.isEnabled(mode);
    if (wasEnabled) {
      if (this.running === "both") this.running = mode === "beat" ? "volume" : "beat";
      else { this.stop(); return; }
    } else {
      this.running = "both";
    }
    // Immediately remove any stale period or speed override from a disabled mode.
    this.mapper = new AudioFeatureMapper();
    for (const channel of ["A", "B"] as const) this.device.setWaveformModulation(channel, null);
  }

  start(session: ControlSession, mode: Exclude<AudioMode, "off">, target: AudioTarget, range: FrequencyRange, onFailure: (message: string) => void): void {
    if (session.snapshot().state !== "active") throw new Error("必须先手动授权并启动会话");
    if (!existsSync(this.helperPath)) throw new Error("音频捕获组件未编译，无法启动声控模式");
    validateFrequencyRange(range);
    this.stop();
    this.running = mode;
    this.destination = target;
    this.frequencyRange = range;
    this.mapper = new AudioFeatureMapper();
    this.onFailure = onFailure;
    this.lastMetricAt = Date.now();
    this.lastRenderAt = 0;
    const generation = this.generation;
    const child = spawn(this.helperPath, [], { stdio: ["ignore", "pipe", "pipe"] });
    this.process = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (this.generation !== generation) return;
      this.reader += chunk;
      if (this.reader.length > 16_384) { this.fail("音频数据流过长"); return; }
      let end = this.reader.indexOf("\n");
      while (end !== -1) {
        const line = this.reader.slice(0, end).trim();
        this.reader = this.reader.slice(end + 1);
        try {
          if (line) this.onMetric(session, JSON.parse(line) as { rms: number });
        } catch { this.fail("音频指标格式无效"); return; }
        end = this.reader.indexOf("\n");
      }
    });
    child.stderr.on("data", (chunk: Buffer) => { console.error("System audio:", chunk.toString().slice(0, 240)); });
    child.on("error", () => { if (this.generation === generation) this.fail("无法启动系统音频捕获"); });
    child.on("exit", () => { if (this.generation === generation) this.fail("系统音频捕获已退出，请检查权限"); });
    this.guardTimer = setInterval(() => {
      if (this.generation !== generation) return;
      if (session.snapshot().state !== "active") { this.stop(); return; }
      if (Date.now() - this.lastMetricAt > 5000) this.fail("连续5秒未收到音频数据，已停止声控会话");
    }, 1000);
    this.guardTimer.unref?.();
  }

  stop(): void {
    this.generation++;
    if (this.guardTimer) clearInterval(this.guardTimer);
    this.guardTimer = null;
    this.process?.kill("SIGTERM");
    this.process = null;
    this.reader = "";
    this.running = null;
    for (const channel of ["A", "B"] as const) this.device.setWaveformModulation(channel, null);
  }

  private onMetric(session: ControlSession, metric: { rms: number }): void {
    if (!this.running) return;
    const now = Date.now();
    this.lastMetricAt = now;
    if (session.snapshot().state !== "active") { this.stop(); return; }
    if (now - this.lastRenderAt < 90) return;
    this.lastRenderAt = now;
    const modulation = this.mapper.update(metric.rms, now, this.running, this.frequencyRange);
    for (const channel of ["A", "B"] as const) {
      this.device.setWaveformModulation(channel, this.destination === "both" || this.destination === channel ? modulation : null);
    }
  }

  private fail(reason: string): void {
    const callback = this.onFailure;
    this.stop();
    callback(reason);
  }
}
