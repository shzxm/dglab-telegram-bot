export type Channel = "A" | "B";

export interface Device {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  getStatus(): Promise<{ connected: boolean; battery: number; strengthA: number; strengthB: number }>;
  setStrength(channel: Channel, strength: number): Promise<void>;
  playWaveform(channel: Channel, waveformId: string, durationMs: number): Promise<void>;
  emergencyStop(): Promise<void>;
}

/** Safe development device. It never talks to Bluetooth or produces output. */
export class MockDevice implements Device {
  connected = false;
  battery = 100;
  strengthA = 0;
  strengthB = 0;
  readonly events: Array<Record<string, unknown>> = [];

  async connect(): Promise<void> {
    this.connected = true;
    this.events.push({ type: "connect" });
  }

  async disconnect(): Promise<void> {
    await this.emergencyStop();
    this.connected = false;
    this.events.push({ type: "disconnect" });
  }

  async getStatus() {
    return { connected: this.connected, battery: this.battery, strengthA: this.strengthA, strengthB: this.strengthB };
  }

  async setStrength(channel: Channel, strength: number): Promise<void> {
    if (!this.connected) throw new Error("device is not connected");
    if (!Number.isInteger(strength) || strength < 0 || strength > 133) throw new Error("invalid strength");
    if (channel === "A") this.strengthA = strength;
    else this.strengthB = strength;
    this.events.push({ type: "setStrength", channel, strength });
  }

  async playWaveform(channel: Channel, waveformId: string, durationMs: number): Promise<void> {
    if (!this.connected) throw new Error("device is not connected");
    if (durationMs < 100 || durationMs > 5000) throw new Error("invalid duration");
    this.events.push({ type: "playWaveform", channel, waveformId, durationMs });
  }

  async emergencyStop(): Promise<void> {
    this.strengthA = 0;
    this.strengthB = 0;
    this.events.push({ type: "emergencyStop" });
  }
}
