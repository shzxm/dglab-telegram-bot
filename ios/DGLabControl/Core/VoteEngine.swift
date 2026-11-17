import Foundation

/// Mirrors the Bot's A/B strength and waveform voting categories.
public final class VoteEngine {
    private var votes: [VoteChoice: Set<Int64>] = [:]
    private var voted: [Int64: Set<String>] = [:]
    public init() {}
    public func vote(user: Int64, choice: VoteChoice) throws -> Int {
        let category = choice.channel.rawValue + ":" + choice.category
        var seen = voted[user] ?? []
        guard !seen.contains(category) else { throw DGControlError.rejected }
        seen.insert(category); voted[user] = seen
        votes[choice, default: []].insert(user)
        return votes[choice]?.count ?? 0
    }
    public func counts() -> [(VoteChoice, Int)] { votes.map { ($0.key, $0.value.count) } }
    public func resolveRound() -> [VoteChoice] {
        defer { votes.removeAll(); voted.removeAll() }
        var winners: [VoteChoice] = []
        for channel in DGChannel.allCases {
            for category in ["strength", "waveform"] {
                let choices = votes.filter { $0.key.channel == channel && $0.key.category == category }
                if let winner = choices.max(by: { $0.value.count < $1.value.count }) { winners.append(winner.key) }
            }
        }
        return winners
    }
}
