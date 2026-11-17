import Foundation

/// Wire encoding directly corresponds to the existing macOS DG-LAB V2 implementation.
/// This is encoding, NOT an endorsement of any intensity as safe for a person.
public enum V2Codec {
    public static let maxSoftwareStrength = 133
    public static let refreshInterval: TimeInterval = 0.1
    public static let serviceUUID = "180B"
    public static let batteryServiceUUID = "180A"
    public static let batteryCharacteristicUUID = "1500"
    public static let strengthCharacteristicUUID = "1504"
    public static let waveACharacteristicUUID = "1506"
    public static let waveBCharacteristicUUID = "1505"

    public static func encodeWave(_ frame: WaveFrame) throws -> Data {
        guard (0...31).contains(frame.x), (0...1023).contains(frame.y), (0...31).contains(frame.z) else { throw DGControlError.invalidFrame }
        let value = frame.x | (frame.y << 5) | (frame.z << 15)
        return Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)])
    }
    public static func encodeStrength(a: Int, b: Int, maxA: Int = 133, maxB: Int = 133) throws -> Data {
        guard a >= 0, b >= 0, a <= maxA, b <= maxB,
              a <= maxSoftwareStrength, b <= maxSoftwareStrength else { throw DGControlError.invalidStrength }
        let rawA = a * 7, rawB = b * 7
        guard rawA <= 2047, rawB <= 2047 else { throw DGControlError.invalidStrength }
        let value = (rawA << 11) | rawB
        return Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)])
    }
    public static func period(forHz hz: Double) throws -> Int {
        guard hz.isFinite, hz >= 1, hz <= 100 else { throw DGControlError.invalidFrequency }
        return max(10, min(1000, Int((1000 / hz).rounded())))
    }
    public static func modulate(_ frame: WaveFrame, with modulation: WaveModulation?) -> WaveFrame {
        guard let period = modulation?.periodMilliseconds, frame.periodMilliseconds > 0 else { return frame }
        let periodMs = max(10, min(1000, period))
        let x = max(1, min(31, Int((sqrt(Double(periodMs)/1000) * 15).rounded())))
        return WaveFrame(x: x, y: periodMs - x, z: frame.z)
    }
}
