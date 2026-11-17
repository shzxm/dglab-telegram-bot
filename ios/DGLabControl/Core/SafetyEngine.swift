import Foundation

/// Fails closed: the session starts idle, caps are explicit and expiry never auto-arms.
/// Local safety policy is independent from the remote Bot owner/voting access rules.
public final class SessionSafetyEngine {
    public private(set) var active = false
    public private(set) var a = 0
    public private(set) var b = 0
    public private(set) var maxA = 0
    public private(set) var maxB = 0
    public private(set) var expiresAt: Date?
    private var operations: [Int64: [Date]] = [:]
    public init() {}
    public func arm(maxA: Int, maxB: Int, duration: TimeInterval, now: Date = Date()) throws {
        guard !active, (0...V2Codec.maxSoftwareStrength).contains(maxA),
              (0...V2Codec.maxSoftwareStrength).contains(maxB),
              duration >= 10, duration <= 86_400 else { throw DGControlError.rejected }
        self.maxA = maxA; self.maxB = maxB
        a = 0; b = 0
        expiresAt = now.addingTimeInterval(duration)
        operations.removeAll()
        active = true
    }
    public func delta(_ channel: DGChannel, _ amount: Int, now: Date = Date()) throws -> (Int, Int) {
        try verify(now)
        guard [-5, -3, -1, 1, 3, 5].contains(amount) else { throw DGControlError.invalidStrength }
        if channel == .A { a = max(0, min(maxA, a + amount)) }
        else { b = max(0, min(maxB, b + amount)) }
        return (a, b)
    }
    public func setAbsolute(a: Int, b: Int, now: Date = Date()) throws -> (Int, Int) {
        try verify(now)
        guard a >= 0, b >= 0, a <= maxA, b <= maxB else { throw DGControlError.invalidStrength }
        self.a = a; self.b = b
        return (a, b)
    }
    public func checkParticipantRate(id: Int64, now: Date = Date()) throws {
        try verify(now)
        let recent = (operations[id] ?? []).filter { now.timeIntervalSince($0) < 1.0 }
        guard recent.count < 3 else { throw DGControlError.rateLimited }
        operations[id] = recent + [now]
    }
    public func verify(_ date: Date = Date()) throws {
        guard active else { throw DGControlError.notArmed }
        if let expiresAt, date >= expiresAt { stop(); throw DGControlError.expired }
    }
    public func stop() {
        active = false; a = 0; b = 0
        expiresAt = nil; operations.removeAll()
    }
}
