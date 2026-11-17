import Foundation

/// Processes only numerical audio RMS. Does not record audio samples.
public final class AudioFeatureMapper {
    private var envelope: Double = 0
    private var previous: Double = 0
    private var lastBeat: TimeInterval = -.infinity
    private var fullSpeed = false
    public init() {}

    public func update(rms: Double, seconds: TimeInterval,
                       volumeEnabled: Bool, beatEnabled: Bool,
                       range: AudioFrequencyRange) throws -> WaveModulation {
        try range.validate()
        guard rms.isFinite, (0...1).contains(rms) else { throw DGControlError.invalidFrame }
        envelope = envelope * 0.65 + rms * 0.35
        var result = WaveModulation()
        if volumeEnabled {
            if !fullSpeed && envelope >= 0.045 { fullSpeed = true }
            else if fullSpeed && envelope <= 0.025 { fullSpeed = false }
            result.speedFactor = fullSpeed ? 1 : 0.25
        }
        if beatEnabled {
            let onset = rms - previous
            if range.minHz != range.maxHz &&
                rms > 0.055 && onset > 0.045 && seconds - lastBeat >= 0.25 { lastBeat = seconds }
            let hz = seconds - lastBeat < 0.28 ? range.maxHz : range.minHz
            result.periodMilliseconds = try V2Codec.period(forHz: Double(hz))
        }
        previous = rms
        return result
    }
}
