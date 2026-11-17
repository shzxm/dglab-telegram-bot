import Foundation
import DGLabCore

func check(_ ok: Bool, _ message: String) { if !ok { fatalError("FAILED: " + message) } }
func checkThrows(_ test: () throws -> Void, _ message: String) {
    do { try test(); fatalError("FAILED: " + message) } catch DGControlError.invalidFrame { } catch DGControlError.invalidStrength { }
    catch { fatalError("Unexpected error: \(error)") }
}
do {
    check(BuiltinWaveforms.all.count == 9, "9 source waveforms")
    check(BuiltinWaveforms.find("imported_3")?.name == "最爱", "name parity")
    check(BuiltinWaveforms.find("imported_3")?.frames.count == 21, "frames parity")
    check(Array(try V2Codec.encodeWave(.init(x: 1, y: 9, z: 20))) == [33,1,10], "V2 waveform bytes")
    let raw = (7 << 11) | 14
    check(Array(try V2Codec.encodeStrength(a: 1, b: 2)) == [UInt8(raw&255),UInt8((raw>>8)&255),UInt8((raw>>16)&255)], "V2 strength bytes")
    checkThrows({ _ = try V2Codec.encodeStrength(a: 134, b: 0) }, "hard limit")
    checkThrows({ _ = try V2Codec.encodeWave(.init(x: 32, y: 0, z: 0)) }, "invalid X")
    let mapper = AudioFeatureMapper()
    let quiet = try mapper.update(rms: 0, seconds: 0, volumeEnabled: true, beatEnabled: true, range: .init(5, 20))
    check(quiet.speedFactor == 0.25 && quiet.periodMilliseconds == 200, "quiet playback")
    let loud = try mapper.update(rms: 0.25, seconds: 1, volumeEnabled: true, beatEnabled: true, range: .init(5,20))
    check(loud.speedFactor == 1 && loud.periodMilliseconds == 50, "loud+beat")
    let fixed = try AudioFeatureMapper().update(rms: 0.9, seconds: 1, volumeEnabled: false, beatEnabled: true, range: .init(1,1))
    check(fixed.periodMilliseconds == 1000, "fixed 1Hz")
    let safety = SessionSafetyEngine()
    let start = Date()
    try safety.arm(maxA: 5, maxB: 7, duration: 20, now: start)
    check(try safety.delta(.A, 5, now: start).0 == 5, "A cap")
    check(try safety.delta(.A, 5, now: start).0 == 5, "A cap remains")
    _ = try safety.setAbsolute(a: 4,b: 6,now:start)
    check(safety.a == 4 && safety.b == 6, "remote absolute within cap")
    let voting = VoteEngine()
    let choice = VoteChoice(channel:.A, category:"strength", action:"+1")
    check(try voting.vote(user:7, choice:choice) == 1, "vote")
    check(voting.resolveRound().count == 1, "vote result")
    print("PASS: V2 bytes, strength caps, 9 waveforms, audio modes, 1Hz, remote limits and voting")
} catch {
    fatalError("DGLabCore checks failed: \(error)")
}
