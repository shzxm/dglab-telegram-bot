import type { Channel, Device } from "./device.js";

export type Mode = "collaboration" | "voting";
export type Action =
  | { type: "strength_delta"; channel: Channel; delta: 1 | 3 | 5 | -1 | -3 | -5 }
  | { type: "waveform"; channel: Channel; waveformId: string; durationMs: number }
  | { type: "stop" };

function actionChannel(action: Action): Channel | null {
  return action.type === "stop" ? null : action.channel;
}

function waveformName(id: string): string {
  return ({ imported_0: "波浪", imported_1: "持续跳跃", imported_2: "渐强持续", imported_3: "最爱", imported_4: "按揉", imported_5: "跳强" } as Record<string, string>)[id] ?? id;
}

export interface SessionConfig {
  id: string;
  chatId: number;
  ownerUserId: number;
  mode: Mode;
  limitA: number;
  limitB: number;
  durationMs: number;
  startedAt: number;
  expiresAt: number;
}

interface Vote {
  voters: Set<number>;
  expiresAt: number;
  action: Action;
}

export interface SessionSnapshot {
  state: "draft" | "active" | "stopped" | "fault";
  mode: Mode;
  participants: number;
  operators: string[];
  currentA: number;
  currentB: number;
  limitA: number;
  limitB: number;
  expiresAt: number;
  voteCounts: Array<{ channel: Channel; action: Action; count: number }>;
  waveformA: string;
  waveformB: string;
}

export class ControlSession {
  private state: SessionSnapshot["state"] = "draft";
  private readonly participants = new Map<number, string>();
  private readonly actionTimes = new Map<number, number[]>();
  private readonly votes = new Map<string, Vote>();
  private readonly votedChannels = new Map<number, Set<string>>();
  private voteRoundTimer: ReturnType<typeof setTimeout> | null = null;
  private waveformA = "波浪";
  private waveformB = "波浪";
  private currentA = 0;
  private currentB = 0;
  private queue: Promise<void> = Promise.resolve();
  private expiryTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly pendingVoteTimers = new Set<ReturnType<typeof setTimeout>>();

  constructor(
    readonly config: SessionConfig,
    private readonly device: Device,
    private readonly hardLimit = 133,
    private readonly voteThreshold = 2,
    private readonly actionCooldownMs = 1000,
    private readonly voteWindowMs = 5000,
    private readonly now: () => number = Date.now,
    private readonly actionsPerWindow = 3,
  ) {}

  addParticipant(userId: number, displayName = String(userId)): void {
    if (this.state !== "active") throw new Error("session is not active");
    this.participants.set(userId, displayName);
  }

  removeParticipant(userId: number): void { this.participants.delete(userId); }

  async arm(): Promise<void> {
    if (this.state !== "draft") throw new Error("session cannot be armed");
    if (!Number.isInteger(this.config.durationMs) || this.config.durationMs < 0 || this.config.durationMs > 24 * 60 * 60_000) throw new Error("invalid session duration");
    if (!Number.isInteger(this.config.limitA) || !Number.isInteger(this.config.limitB) || this.config.limitA < 0 || this.config.limitB < 0 || this.config.limitA > this.hardLimit || this.config.limitB > this.hardLimit) throw new Error("invalid session limits");
    await this.device.connect();
    try {
      await this.device.emergencyStop();
      const startedAt = this.now();
      this.config.startedAt = startedAt;
      this.config.expiresAt = this.config.durationMs > 0 ? startedAt + this.config.durationMs : 0;
      this.state = "active";
      if (this.config.durationMs > 0) {
        this.expiryTimer = setTimeout(() => {
          void this.stop().catch(() => { this.state = "fault"; });
        }, this.config.durationMs);
        this.expiryTimer.unref?.();
      }
    } catch (error) {
      await this.device.emergencyStop().catch(() => undefined);
      await this.device.disconnect().catch(() => undefined);
      throw error;
    }
  }

  isParticipant(userId: number): boolean { return this.participants.has(userId); }

  async submit(userId: number, action: Action): Promise<{ accepted: boolean; votes: number; required: number }> {
    this.expireIfNeeded();
    if (this.state !== "active") throw new Error("会话尚未启动");
    if (!this.participants.has(userId)) throw new Error("你还没有加入会话");
    if (action.type !== "stop") {
      const now = this.now();
      const times = (this.actionTimes.get(userId) ?? []).filter((time) => now - time < (this.actionCooldownMs > 0 ? this.actionCooldownMs : 1000));
      if (times.length >= this.actionsPerWindow) throw new Error(`操作太频繁，每位用户每秒最多操作 ${this.actionsPerWindow} 次，请稍后再试`);
      times.push(now);
      this.actionTimes.set(userId, times);
    }
    if (action.type === "stop") {
      await this.stop();
      return { accepted: true, votes: 0, required: 0 };
    }
    if (this.config.mode === "collaboration") {
      await this.enqueue(action);
      return { accepted: true, votes: 1, required: 1 };
    }
    const voteChannel = action.channel;
    const voteCategory = `${voteChannel}:${action.type === "waveform" ? "waveform" : "strength"}`;
    const userChannels = this.votedChannels.get(userId) ?? new Set<string>();
    if (userChannels.has(voteCategory)) throw new Error(`本轮投票中，你已经为 ${voteChannel} 通道的${action.type === "waveform" ? "波形" : "强度"}投过票`);
    userChannels.add(voteCategory);
    this.votedChannels.set(userId, userChannels);
    const key = JSON.stringify(action);
    const existing = this.votes.get(key);
    const vote = existing ?? { voters: new Set<number>(), expiresAt: this.now() + this.voteWindowMs, action };
    vote.voters.add(userId);
    this.votes.set(key, vote);
    if (!this.voteRoundTimer) {
      this.voteRoundTimer = setTimeout(() => {
        this.voteRoundTimer = null;
        const entries = [...this.votes.values()];
        this.votes.clear();
        this.votedChannels.clear();
        if (!entries.length || this.state !== "active") return;
        for (const channel of ["A", "B"] as const) {
          for (const category of ["strength", "waveform"] as const) {
            const channelEntries = entries.filter((item) => actionChannel(item.action) === channel && (item.action.type === "waveform" ? "waveform" : "strength") === category);
            if (!channelEntries.length) continue;
            const highest = Math.max(...channelEntries.map((item) => item.voters.size));
            const winners = channelEntries.filter((item) => item.voters.size === highest);
            if (winners.length === 1 && winners[0]) void this.enqueue(winners[0].action).catch(() => undefined);
          }
        }
      }, this.voteWindowMs);
      this.voteRoundTimer.unref?.();
    }
    return { accepted: false, votes: vote.voters.size, required: this.voteThreshold };
  }

  async applyOwnerAction(action: Action): Promise<void> {
    this.expireIfNeeded();
    if (this.state !== "active") throw new Error("会话尚未启动");
    await this.enqueue(action);
  }

  snapshot(): SessionSnapshot {
    this.expireIfNeeded();
    return { state: this.state, mode: this.config.mode, participants: this.participants.size, operators: [...this.participants.values()], currentA: this.currentA, currentB: this.currentB, limitA: this.config.limitA, limitB: this.config.limitB, expiresAt: this.config.expiresAt, voteCounts: [...this.votes.values()].flatMap((vote) => { const channel = actionChannel(vote.action); return channel ? [{ channel, action: vote.action, count: vote.voters.size }] : []; }), waveformA: this.waveformA, waveformB: this.waveformB };
  }

  async stop(): Promise<void> {
    this.votes.clear();
    this.votedChannels.clear();
    if (this.voteRoundTimer) clearTimeout(this.voteRoundTimer);
    this.voteRoundTimer = null;
    for (const timer of this.pendingVoteTimers) clearTimeout(timer);
    this.pendingVoteTimers.clear();
    this.state = "stopped";
    if (this.expiryTimer) clearTimeout(this.expiryTimer);
    this.expiryTimer = null;
    try {
      await this.device.emergencyStop();
    } finally {
      this.currentA = 0;
      this.currentB = 0;
    }
  }

  private async enqueue(action: Action): Promise<void> {
    this.queue = this.queue
      .catch(async () => {
        this.state = "fault";
        await this.device.emergencyStop().catch(() => undefined);
      })
      .then(() => this.execute(action))
      .catch(async (error: unknown) => {
        this.state = "fault";
        await this.device.emergencyStop().catch(() => undefined);
        throw error;
      });
    return this.queue;
  }

  private async execute(action: Action): Promise<void> {
    if (this.state !== "active") return;
    if (action.type === "waveform") {
      if (action.channel === "A") this.waveformA = waveformName(action.waveformId);
      else this.waveformB = waveformName(action.waveformId);
      void this.device.playWaveform(action.channel, action.waveformId, action.durationMs).catch(async () => {
        this.state = "fault";
        await this.device.emergencyStop().catch(() => undefined);
      });
      return;
    }
    if (action.type === "stop") return;
    const channel = action.channel;
    const current = channel === "A" ? this.currentA : this.currentB;
    const limit = Math.min(this.hardLimit, channel === "A" ? this.config.limitA : this.config.limitB);
    const next = Math.max(0, Math.min(limit, current + action.delta));
    await this.device.setStrength(channel, next);
    if (channel === "A") this.currentA = next;
    else this.currentB = next;
  }

  private expireIfNeeded(): void {
    if (this.state === "active" && this.config.expiresAt > 0 && this.now() >= this.config.expiresAt) {
      void this.stop();
    }
    for (const [key, vote] of this.votes) if (vote.expiresAt <= this.now()) this.votes.delete(key);
  }
}
