import type { Channel, Device, WaveformModulation } from "./device.js";
import type { IOSBridgeServer } from "./ios-bridge.js";

/** A DG-LAB device hosted by a physically consenting iPhone via private WebSocket. */
export class IOSRelayDevice implements Device {
  private connected = false;
  private a = 0;
  private b = 0;
  private battery = 0;
  private initialZeroPending = false;
  constructor(private readonly bridge: IOSBridgeServer) {}
  async connect(): Promise<void> {
    const result = await this.bridge.hostCommand("device.connect", {}, 65_000);
    if (result.armed !== true || result.connected !== true) throw new Error("Local iPhone host did not authorize this session");
    this.connected = true;
    this.initialZeroPending = true;
    this.a = 0; this.b = 0;
    this.battery = Number(result.battery) || 0;
  }
  async disconnect(): Promise<void> {
    try { await this.emergencyStop(); await this.bridge.hostCommand("device.disconnect"); }
    finally { this.connected = false; this.a = 0; this.b = 0; }
  }
  async getStatus() {
    return { connected: this.connected && this.bridge.hostConnected,
             battery: this.battery, strengthA: this.a, strengthB: this.b };
  }
  async setStrength(channel: Channel, value: number): Promise<void> {
    if (!this.connected || !this.bridge.hostConnected) throw new Error("Phone BLE host disconnected");
    if (!Number.isInteger(value) || value < 0 || value > 133) throw new Error("Invalid strength");
    const nextA = channel === "A" ? value : this.a;
    const nextB = channel === "B" ? value : this.b;
    await this.bridge.hostCommand("device.strength", { a: nextA, b: nextB });
    this.a = nextA; this.b = nextB;
  }
  async playWaveform(channel: Channel, waveformId: string, durationMs: number): Promise<void> {
    if (!this.connected) throw new Error("iPhone BLE host disconnected");
    await this.bridge.hostCommand("device.waveform", { channel, waveformId, durationMs });
  }
  async emergencyStop(): Promise<void> {
    // The existing ControlSession calls emergencyStop immediately after connect,
    // before entering active state. Zero WITHOUT canceling local host consent then.
    if (this.initialZeroPending) {
      this.initialZeroPending = false;
      await this.bridge.hostCommand("device.zero");
    } else if (this.connected && this.bridge.hostConnected) {
      await this.bridge.hostCommand("device.emergency");
    }
    this.a = 0; this.b = 0;
  }
  setWaveformModulation(channel: Channel, modulation: WaveformModulation | null): void {
    if (!this.connected || !this.bridge.hostConnected) return;
    void this.bridge.hostCommand("device.modulation", {
      channel, ...(modulation?.speedFactor != null ? { speedFactor: modulation.speedFactor } : {}),
      ...(modulation?.periodMs != null ? { periodMs: modulation.periodMs } : {}),
    }).catch(() => undefined);
  }
  onHostLost(): void { this.connected = false; this.a = 0; this.b = 0; this.initialZeroPending = false; }
}
