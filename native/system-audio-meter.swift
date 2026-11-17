// Capture only macOS system output audio. Emits a JSON RMS value for each audio buffer.
// Does not record, retain, transmit or save audio samples.
import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation

final class SystemAudioMeter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var lastSent = Date.distantPast
    private let lock = NSLock()
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                guard let formatDescription = sampleBuffer.formatDescription,
                      let asbd = formatDescription.audioStreamBasicDescription,
                      let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer),
                      let channels = pcm.floatChannelData else { return }
                let channelCount = Int(pcm.format.channelCount)
                let frameCount = Int(pcm.frameLength)
                guard channelCount > 0 && frameCount > 0 else { return }
                var sum: Double = 0
                for channel in 0..<channelCount {
                    let samples = channels[channel]
                    for index in 0..<frameCount {
                        let value = Double(samples[index])
                        sum += value * value
                    }
                }
                let rms = sqrt(sum / Double(channelCount * frameCount))
                lock.lock()
                defer { lock.unlock() }
                if Date().timeIntervalSince(lastSent) >= 0.09 {
                    lastSent = Date()
                    print(String(format: "{\"rms\":%.6f}", min(1.0, rms)))
                    fflush(stdout)
                }
            }
        } catch { fputs("audio buffer error: \(error)\n", stderr) }
    }

    // An open capture stream may not emit buffers while the system is genuinely silent.
    // Report silence separately from stream failure, without storing audio.
    func emitSilenceIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastSent) > 0.3 {
            lastSent = Date()
            print("{\"rms\":0.0}")
            fflush(stdout)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("system audio capture ended: \(error)\n", stderr)
        exit(1)
    }
}

@main struct Main {
    static func main() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw NSError(domain: "DGLabAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"] ) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            let meter = SystemAudioMeter()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: meter)
            try stream.addStreamOutput(meter, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.dglab.audio.capture"))
            try await stream.startCapture()
            if CommandLine.arguments.contains("--permission-test") {
                // This is requested only by a dedicated user-visible button.
                // The stream is stopped immediately and never saves audio data.
                try await Task.sleep(for: .milliseconds(700))
                try await stream.stopCapture()
                print("{\"permission_test_ok\":true}")
                return
            }
            fputs("system audio capture started\n", stderr)
            let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in meter.emitSilenceIfIdle() }
            // Retain the stream until the parent process terminates us.
            _ = heartbeat
            withExtendedLifetime((stream, meter)) { RunLoop.current.run() }
        } catch {
            fputs("system audio capture unavailable: \(error)\n", stderr)
            exit(1)
        }
    }
}
