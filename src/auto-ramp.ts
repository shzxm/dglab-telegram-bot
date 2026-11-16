import type { ControlSession } from "./control.js";
import type { Channel } from "./device.js";

/** Independent A/B automatic ramp, bounded by a user-set count AND session strength limit. */
export class AutoRampController {
  private readonly timers: Partial<Record<Channel, ReturnType<typeof setInterval>>> = {};
  private readonly generations: Record<Channel, number> = { A: 0, B: 0 };
  private readonly applying: Record<Channel, boolean> = { A: false, B: false };
  private readonly runIds: Record<Channel, number> = { A: 0, B: 0 };
  private readonly progress: Record<Channel, number> = { A: 0, B: 0 };
  private readonly maxIncreases: Record<Channel, number> = { A: 33, B: 33 };
  private readonly sessions: Partial<Record<Channel, ControlSession>> = {};
  private readonly rates: Record<Channel, number> = { A: 3, B: 3 };

  isEnabled(channel: Channel): boolean { return this.timers[channel] !== undefined; }
  completed(channel: Channel): number { return this.progress[channel]; }
  maximum(channel: Channel): number { return this.maxIncreases[channel]; }
  rate(channel: Channel): number { return this.rates[channel]; }
  static validateRate(seconds: number): void {
    if (!Number.isInteger(seconds) || seconds < 1 || seconds > 60) throw new Error("自动提升间隔须在1至60秒之间");
  }
  static validateMaximum(count: number): void {
    if (!Number.isInteger(count) || count < 1 || count > 33) throw new Error("累计提升次数须在1至33之间");
  }
  start(session: ControlSession, channel: Channel, rateSeconds: number, maxIncrease = 33): void {
    if (session.snapshot().state !== "active") throw new Error("请先创建并启动会话");
    AutoRampController.validateRate(rateSeconds);
    AutoRampController.validateMaximum(maxIncrease);
    this.stop(channel);
    this.runIds[channel] += 1;
    this.progress[channel] = 0;
    this.rates[channel] = rateSeconds;
    this.maxIncreases[channel] = maxIncrease;
    this.sessions[channel] = session;
    const state = session.snapshot();
    if ((channel === "A" ? state.currentA >= state.limitA : state.currentB >= state.limitB)) return;
    this.armTimer(channel);
  }
  /** Interval changes do not reset progress or allow a new 33-step ramp. */
  updateRate(channel: Channel, rateSeconds: number): void {
    AutoRampController.validateRate(rateSeconds);
    this.rates[channel] = rateSeconds;
    if (this.isEnabled(channel)) this.armTimer(channel);
  }
  /** If the new limit is below the already-completed count, stop immediately. */
  updateMaximum(channel: Channel, maxIncrease: number): void {
    AutoRampController.validateMaximum(maxIncrease);
    this.maxIncreases[channel] = maxIncrease;
    if (this.isEnabled(channel) && this.progress[channel] >= maxIncrease) this.stop(channel);
  }
  stop(channel?: Channel): void {
    if (!channel) { this.stop("A"); this.stop("B"); return; }
    this.generations[channel] += 1;
    if (this.timers[channel]) clearInterval(this.timers[channel]);
    delete this.timers[channel];
    delete this.sessions[channel];
  }
  private armTimer(channel: Channel): void {
    if (this.timers[channel]) clearInterval(this.timers[channel]);
    this.generations[channel] += 1;
    const generation = this.generations[channel];
    const runId = this.runIds[channel];
    this.timers[channel] = setInterval(() => {
      void this.tick(channel, generation, runId);
    }, this.rates[channel] * 1000);
    this.timers[channel]?.unref?.();
  }
  private async tick(channel: Channel, generation: number, runId: number): Promise<void> {
    const session = this.sessions[channel];
    if (!session || !this.isEnabled(channel) || this.generations[channel] !== generation || this.applying[channel]) return;
    this.applying[channel] = true;
    try {
      const state = session.snapshot();
      if (state.state !== "active") { this.stop(); return; }
      const before = channel === "A" ? state.currentA : state.currentB;
      const strengthLimit = channel === "A" ? state.limitA : state.limitB;
      if (this.progress[channel] >= this.maxIncreases[channel] || before >= strengthLimit) {
        this.stop(channel); return;
      }
      await session.applyOwnerAction({ type: "strength_delta", channel, delta: 1 });
      // A change of interval reschedules the timer but must NOT discard a step
      // already acknowledged by the device from the same ramp run.
      if (this.runIds[channel] !== runId || this.sessions[channel] !== session) return;
      const afterState = session.snapshot();
      const after = channel === "A" ? afterState.currentA : afterState.currentB;
      if (after > before) this.progress[channel] += 1;
      if (!this.isEnabled(channel)) return;
      if (after <= before || after >= strengthLimit || this.progress[channel] >= this.maxIncreases[channel]) this.stop(channel);
    } catch {
      // On any device/session fault stop both channels rather than repeatedly writing.
      this.stop();
    } finally {
      this.applying[channel] = false;
    }
  }
}
