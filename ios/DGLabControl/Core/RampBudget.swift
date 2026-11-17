import Foundation

/// Counts *successful automatic one-level increases*, not manual adjustments.
/// Reaching either the configured budget or the channel's independent cap ends the ramp.
public struct RampBudget: Equatable, Sendable {
    public static let allowedIncrease = 1...33
    public static let allowedInterval = 1...60
    public private(set) var completed: Int = 0
    public private(set) var maximum: Int

    public init(maximum: Int) throws {
        guard Self.allowedIncrease.contains(maximum) else { throw DGControlError.invalidStrength }
        self.maximum = maximum
    }
    public var remaining: Int { max(0, maximum - completed) }
    public var isComplete: Bool { completed >= maximum }

    public mutating func updateMaximum(_ value: Int) throws {
        guard Self.allowedIncrease.contains(value) else { throw DGControlError.invalidStrength }
        maximum = value
    }
    public mutating func registerSuccessfulStep() {
        if !isComplete { completed += 1 }
    }
    public static func validateInterval(_ seconds: Int) throws {
        guard allowedInterval.contains(seconds) else { throw DGControlError.rejected }
    }
}
