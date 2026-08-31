import noble, { type Characteristic, type Peripheral } from "@stoprocent/noble";
import type { Channel, Device } from "./device.js";
import { IMPORTED_V2_WAVEFORMS, type V2Frame } from "./waveform-compiler.js";

export const COYOTE_V2_NAME = "D-LAB ESTIM01";
export const V2_SERVICE = "180b";
export const V2_BATTERY_SERVICE = "180a";
export const V2_BATTERY_CHAR = "1500";
export const V2_STRENGTH_CHAR = "1504";
export const V2_B_WAVE_CHAR = "1505";
export const V2_A_WAVE_CHAR = "1506";

export const V2_WAVEFORMS: Record<string, V2Frame[]> = {
  soft: [[1, 9, 0], [1, 9, 4], [1, 9, 8], [1, 9, 12], [1, 9, 16], [1, 9, 20], [1, 9, 0]],
  rhythm: [[5, 95, 8], [5, 95, 16], [5, 95, 20], [1, 9, 8], [1, 9, 16], [1, 9, 20]],
  rise: [[1, 14, 4], [1, 9, 8], [1, 9, 12], [1, 9, 16], [1, 9, 20], [1, 9, 0]],
  ...IMPORTED_V2_WAVEFORMS,
};

/** V2 packs X (5 bits), Y (10 bits), Z (5 bits) into little-endian 24 bits. */
export function encodeWaveFrame(x: number, y: number, z: number): Buffer {
  if (!Number.isInteger(x) || x < 0 || x > 31) throw new Error("x must be 0..31");
  if (!Number.isInteger(y) || y < 0 || y > 1023) throw new Error("y must be 0..1023");
  if (!Number.isInteger(z) || z < 0 || z > 31) throw new Error("z must be 0..31");
  const packed = x | (y << 5) | (z << 15);
  return Buffer.from([packed & 0xff, (packed >>> 8) & 0xff, (packed >>> 16) & 0xff]);
}

/** V2 packs A into bits 11..21 and B into bits 0..10. */
export function encodeStrengthFrame(a: number, b: number): Buffer {
  if (!Number.isInteger(a) || a < 0 || a > 2047) throw new Error("a must be 0..2047");
  if (!Number.isInteger(b) || b < 0 || b > 2047) throw new Error("b must be 0..2047");
  const packed = (a << 11) | b;
  return Buffer.from([packed & 0xff, (packed >>> 8) & 0xff, (packed >>> 16) & 0xff]);
}

/** Direct V2 BLE implementation. It is not instantiated in Mock mode. */
export class CoyoteV2Device implements Device {
  private peripheral: Peripheral | null = null;
  private strength: Characteristic | null = null;
  private aWave: Characteristic | null = null;
  private bWave: Characteristic | null = null;
  private batteryChar: Characteristic | null = null;
  private a = 0;
  private b = 0;
  private battery = 0;
  private waveformGenerationA = 0;
  private waveformGenerationB = 0;

  constructor(private readonly targetName = COYOTE_V2_NAME) {}

  async connect(): Promise<void> {
    if (this.peripheral?.state === "connected") return;
    await noble.waitForPoweredOnAsync();
    const peripheral = await this.findPeripheral();
    try {
      await peripheral.connectAsync();
      const { services } = await peripheral.discoverAllServicesAndCharacteristicsAsync();
      const service = services.find((candidate) => normalize(candidate.uuid) === V2_SERVICE);
      if (!service) throw new Error(`DG-LAB V2 service ${V2_SERVICE} not found; discovered: ${services.map((item) => item.uuid).join(", ")}`);
      const chars = service.characteristics ?? [];
      this.strength = findCharacteristic(chars, V2_STRENGTH_CHAR);
      this.bWave = findCharacteristic(chars, V2_B_WAVE_CHAR);
      this.aWave = findCharacteristic(chars, V2_A_WAVE_CHAR);
      const batteryService = services.find((candidate) => normalize(candidate.uuid) === V2_BATTERY_SERVICE);
      this.batteryChar = batteryService ? findCharacteristic(batteryService.characteristics ?? [], V2_BATTERY_CHAR) : null;
      this.peripheral = peripheral;
      if (this.batteryChar) {
        const value = await this.batteryChar.readAsync();
        this.battery = value[0] ?? 0;
      }
      await this.emergencyStop();
    } catch (error) {
      await peripheral.disconnectAsync().catch(() => undefined);
      this.peripheral = null;
      this.strength = null;
      this.aWave = null;
      this.bWave = null;
      this.batteryChar = null;
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`DG-LAB V2 connection failed: ${detail}; characteristics: ${servicesForError(peripheral)}`);
    }
  }

  async disconnect(): Promise<void> {
    await this.emergencyStop();
    if (this.peripheral) await this.peripheral.disconnectAsync();
    this.peripheral = null;
  }

  async getStatus() {
    return { connected: this.peripheral?.state === "connected", battery: this.battery, strengthA: this.a, strengthB: this.b };
  }

  async setStrength(channel: Channel, strength: number): Promise<void> {
    if (!Number.isInteger(strength) || strength < 0 || strength > 133) throw new Error("strength must be 0..133");
    const nextA = channel === "A" ? Math.round(strength * 7) : Math.round(this.a * 7);
    const nextB = channel === "B" ? Math.round(strength * 7) : Math.round(this.b * 7);
    if (nextA > 2047 || nextB > 2047) throw new Error("strength exceeds V2 device range");
    await this.require(this.strength).writeAsync(encodeStrengthFrame(nextA, nextB), true);
    if (channel === "A") this.a = strength;
    else this.b = strength;
  }

  async playWaveform(channel: Channel, waveformId: string, durationMs: number): Promise<void> {
    const characteristic = this.require(channel === "A" ? this.aWave : this.bWave);
    const frames = V2_WAVEFORMS[waveformId];
    if (!frames) throw new Error(`unknown V2 waveform: ${waveformId}`);
    const generation = channel === "A" ? ++this.waveformGenerationA : ++this.waveformGenerationB;
    const currentGeneration = () => channel === "A" ? this.waveformGenerationA : this.waveformGenerationB;
    const endAt = durationMs >= 9999 ? Number.POSITIVE_INFINITY : Date.now() + Math.max(100, durationMs);
    // V2 consumes each waveform frame for roughly 100 ms, so refresh until the deadline.
    let frameIndex = 0;
    while (Date.now() < endAt && generation === currentGeneration()) {
      const frame = frames[frameIndex % frames.length];
      if (!frame) break;
      await characteristic.writeAsync(encodeWaveFrame(...frame), true);
      frameIndex += 1;
      await sleep(100);
    }
    if (generation === currentGeneration() && this.peripheral?.state === "connected") {
      await characteristic.writeAsync(encodeWaveFrame(0, 0, 0), true);
    }
  }

  async emergencyStop(): Promise<void> {
    this.waveformGenerationA += 1;
    this.waveformGenerationB += 1;
    if (this.strength && this.peripheral?.state === "connected") {
      await this.strength.writeAsync(encodeStrengthFrame(0, 0), true);
      await this.aWave?.writeAsync(encodeWaveFrame(0, 0, 0), true);
      await this.bWave?.writeAsync(encodeWaveFrame(0, 0, 0), true);
    }
    this.a = 0;
    this.b = 0;
  }

  private require<T>(value: T | null): T {
    if (!value) throw new Error("DG-LAB V2 is not connected");
    return value;
  }

  private async findPeripheral(): Promise<Peripheral> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        noble.removeListener("discover", onDiscover);
        void noble.stopScanningAsync().catch(() => undefined);
        reject(new Error(`DG-LAB device ${this.targetName} not found within 15 seconds`));
      }, 15_000);
      const onDiscover = (peripheral: Peripheral) => {
        const name = peripheral.advertisement?.localName ?? "";
        if (name !== this.targetName) return;
        clearTimeout(timeout);
        noble.removeListener("discover", onDiscover);
        void noble.stopScanningAsync().catch(() => undefined);
        resolve(peripheral);
      };
      noble.on("discover", onDiscover);
      void noble.startScanningAsync([], false).catch((error: unknown) => {
        clearTimeout(timeout);
        noble.removeListener("discover", onDiscover);
        reject(error);
      });
    });
  }
}

function normalize(uuid: string): string {
  const compact = uuid.replaceAll("-", "").toLowerCase();
  return compact.length === 4 || compact.startsWith("0000") || compact.startsWith("955a")
    ? compact.length === 4 ? compact : compact.slice(4, 8)
    : compact;
}
function findCharacteristic(chars: Characteristic[], uuid: string): Characteristic {
  const found = chars.find((candidate) => normalize(candidate.uuid) === uuid);
  if (!found) throw new Error(`DG-LAB V2 characteristic ${uuid} not found`);
  return found;
}

function servicesForError(peripheral: Peripheral): string {
  const services = peripheral.services ?? [];
  return services.flatMap((service) => (service.characteristics ?? []).map((char) => `${char.uuid}[${char.properties.join("|")}]`)).join(", ");
}

function sleep(ms: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, ms)); }
