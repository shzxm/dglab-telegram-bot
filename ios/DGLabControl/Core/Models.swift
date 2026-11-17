import Foundation

public enum DGChannel: String, CaseIterable, Codable, Identifiable, Sendable {
    case A, B
    public var id: String { rawValue }
    public var label: String { rawValue + " 通道" }
}
public enum SessionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case collaboration = "管理员"
    case voting = "投票"
    case event = "活动/直播"
    public var id: String { rawValue }
}
public enum AudioResponseMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case volume = "音量响应"
    case beat = "节拍响应"
    public var id: String { rawValue }
}
public enum AudioInputSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case microphone = "麦克风"
    case appAudio = "App 内音频"
    case mbpAudio = "MBP 系统音频"
    public var id: String { rawValue }
}
public enum ControlRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case standalone = "iPhone 独立控制"
    case host = "iPhone 作为蓝牙主机"
    case remote = "远程控制现有 Bot"
    public var id: String { rawValue }
}
public struct WaveFrame: Codable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let z: Int
    public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
    public var periodMilliseconds: Int { x + y }
    public var frequency: Double { periodMilliseconds > 0 ? 1000.0 / Double(periodMilliseconds) : 0 }
}
public struct WaveformPreset: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let frames: [WaveFrame]
    public init(id: String, name: String, frames: [WaveFrame]) {
        self.id = id; self.name = name; self.frames = frames
    }
    public var duration: TimeInterval { Double(frames.count) * 0.1 }
}
public struct AudioFrequencyRange: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let minHz: Int
    public let maxHz: Int
    public var id: String { "\(minHz)-\(maxHz)" }
    public var label: String { minHz == maxHz ? "固定 \(minHz) Hz" : "\(minHz)–\(maxHz) Hz" }
    public init(_ min: Int, _ max: Int) { minHz = min; maxHz = max }
    public static let presets: [Self] = [.init(1,1), .init(20,20), .init(50,50), .init(100,100),
                                          .init(5,15), .init(10,30), .init(20,50), .init(1,100)]
    public func validate() throws {
        guard minHz >= 1, maxHz <= 100, minHz <= maxHz else { throw DGControlError.invalidFrequency }
    }
}
public struct WaveModulation: Equatable, Sendable {
    public var speedFactor: Double? = nil
    public var periodMilliseconds: Int? = nil
    public init(speedFactor: Double? = nil, periodMilliseconds: Int? = nil) {
        self.speedFactor = speedFactor
        self.periodMilliseconds = periodMilliseconds
    }
}
public enum DGControlError: LocalizedError, Equatable, Sendable {
    case invalidFrequency, invalidFrame, invalidStrength, notConnected, notArmed
    case expired, rateLimited, relayDisconnected, noPermission, requestTimedOut, rejected
    public var errorDescription: String? {
        switch self {
        case .invalidFrequency: return "波形频率必须在 1–100 Hz 之间"
        case .invalidFrame: return "蓝牙波形参数无效"
        case .invalidStrength: return "强度超过设置上限"
        case .notConnected: return "请先连接 DG-LAB 设备"
        case .notArmed: return "请先在设备旁确认并授权会话"
        case .expired: return "控制会话已到期"
        case .rateLimited: return "操作太频繁，请稍后"
        case .relayDisconnected: return "Telegram 桥接连接已断开"
        case .noPermission: return "尚未获得必要权限"
        case .requestTimedOut: return "远程命令超时，操作未确认"
        case .rejected: return "设备端拒绝远程操作"
        }
    }
}
public struct VoteChoice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let channel: DGChannel
    public let category: String
    public let action: String
    public init(channel: DGChannel, category: String, action: String) {
        self.channel = channel; self.category = category; self.action = action
        self.id = "\(channel.rawValue):\(category):\(action)"
    }
}
public struct Participant: Identifiable, Codable, Sendable {
    public let id: Int64
    public var displayName: String
    public var isOperator: Bool
    public init(id: Int64, displayName: String, isOperator: Bool = false) {
        self.id = id; self.displayName = displayName; self.isOperator = isOperator
    }
}
