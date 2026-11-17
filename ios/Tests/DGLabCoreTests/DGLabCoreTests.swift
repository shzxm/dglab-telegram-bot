import XCTest
@testable import DGLabCore

final class DGLabCoreTests: XCTestCase {
    func testWavePacking() throws {
        XCTAssertEqual(Array(try V2Codec.encodeWave(WaveFrame(x: 1, y: 9, z: 20))), [33, 1, 10])
        XCTAssertThrowsError(try V2Codec.encodeWave(WaveFrame(x: 32, y: 0, z: 0)))
    }
    func testStrengthPackingAndLimit() throws {
        let raw = (7 << 11) | 14
        XCTAssertEqual(Array(try V2Codec.encodeStrength(a: 1, b: 2)), [UInt8(raw & 255), UInt8((raw >> 8) & 255), UInt8((raw >> 16) & 255)])
        XCTAssertThrowsError(try V2Codec.encodeStrength(a: 134, b: 0))
    }
    func testNineImportedAndNativeWaveforms() {
        XCTAssertEqual(BuiltinWaveforms.all.count, 9)
        XCTAssertEqual(BuiltinWaveforms.find("imported_3")?.name, "最爱")
        XCTAssertEqual(BuiltinWaveforms.find("imported_3")?.frames.count, 21)
    }
    func testAudioCombinedAndSilent() throws {
        let mapper = AudioFeatureMapper()
        let slow = try mapper.update(rms: 0, seconds: 0, volumeEnabled: true, beatEnabled: true, range: .init(5,20))
        XCTAssertEqual(slow.speedFactor, 0.25)
        XCTAssertEqual(slow.periodMilliseconds, 200)
        let peak = try mapper.update(rms: 0.25, seconds: 1, volumeEnabled: true, beatEnabled: true, range: .init(5,20))
        XCTAssertEqual(peak.speedFactor, 1)
        XCTAssertEqual(peak.periodMilliseconds, 50)
    }
    func testFixedOneHz() throws {
        let output = try AudioFeatureMapper().update(rms: 0.9, seconds: 1, volumeEnabled: false, beatEnabled: true, range: .init(1,1))
        XCTAssertEqual(output.periodMilliseconds, 1000)
    }
    func testSafetyCapAndExpiry() throws {
        let engine = SessionSafetyEngine()
        XCTAssertThrowsError(try engine.delta(.A, 1))
        let base = Date()
        try engine.arm(maxA: 5, maxB: 7, duration: 20, now: base)
        XCTAssertEqual(try engine.delta(.A, 5, now: base).0, 5)
        XCTAssertEqual(try engine.delta(.A, 5, now: base).0, 5)
        XCTAssertThrowsError(try engine.delta(.B, 1, now: base.addingTimeInterval(21)))
        XCTAssertFalse(engine.active)
    }
    func testRampBudgetExactAndBounds() throws {
        XCTAssertThrowsError(try RampBudget(maximum: 0))
        XCTAssertThrowsError(try RampBudget(maximum: 34))
        XCTAssertThrowsError(try RampBudget.validateInterval(0))
        XCTAssertThrowsError(try RampBudget.validateInterval(61))
        try RampBudget.validateInterval(1)
        try RampBudget.validateInterval(60)
        var ramp = try RampBudget(maximum: 3)
        XCTAssertEqual(ramp.completed, 0)
        ramp.registerSuccessfulStep()
        ramp.registerSuccessfulStep()
        XCTAssertEqual(ramp.remaining, 1)
        try ramp.updateMaximum(2)
        XCTAssertTrue(ramp.isComplete)
        ramp.registerSuccessfulStep()
        XCTAssertEqual(ramp.completed, 2)
        try ramp.updateMaximum(33)
        XCTAssertFalse(ramp.isComplete)
        for _ in 0..<33 { ramp.registerSuccessfulStep() }
        XCTAssertEqual(ramp.completed, 33)
        XCTAssertTrue(ramp.isComplete)
    }
    func testCustomFrequencyRange() throws {
        let range = AudioFrequencyRange(5, 88)
        try range.validate()
        let mapper = AudioFeatureMapper()
        let quiet = try mapper.update(rms: 0, seconds: 0, volumeEnabled: false, beatEnabled: true, range: range)
        XCTAssertEqual(quiet.periodMilliseconds, 200)
        let beat = try mapper.update(rms: 0.3, seconds: 1, volumeEnabled: false, beatEnabled: true, range: range)
        XCTAssertEqual(beat.periodMilliseconds, try V2Codec.period(forHz: 88))
        XCTAssertThrowsError(try AudioFrequencyRange(5, 101).validate())
    }
    func testVoteOnePerCategory() throws {
        let engine = VoteEngine()
        let choice = VoteChoice(channel: .A, category: "strength", action: "+1")
        XCTAssertEqual(try engine.vote(user: 5, choice: choice), 1)
        XCTAssertThrowsError(try engine.vote(user: 5, choice: choice))
        XCTAssertEqual(engine.resolveRound().count, 1)
    }
}
