import Foundation

/// Per-match estimates only. Server snapshots remain the persisted source of truth.
public struct AccountQuestEstimate {
    public enum Metric: String { case heroPowerUses, manaSpent }
    public private(set) var matchID: String?
    public var hasBaseline: Bool { scope != nil }
    private var scope: String?
    private var baseline: [Int: Int] = [:]
    private var totals: [Metric: Int] = [:]

    public init() {}

    public mutating func beginMatch(_ id: String, eligible: Bool) {
        self = AccountQuestEstimate()
        if eligible && !id.isEmpty { matchID = id }
    }

    public mutating func bind(_ snapshot: AccountProgressSnapshot, scope: String) {
        guard matchID != nil else { return }
        if let previous = self.scope {
            if previous != scope { self = AccountQuestEstimate() }
            return // Never add a match total to a newer, partially updated baseline.
        }
        self.scope = scope
        baseline = Dictionary(snapshot.quests.map { ($0.id, $0.progress) }, uniquingKeysWith: { _, last in last })
    }

    @discardableResult
    public mutating func observe(_ metric: Metric, total: Int, matchID: String, isLocalPlayer: Bool) -> Bool {
        guard self.matchID == matchID, isLocalPlayer, total > (totals[metric] ?? 0) else { return false }
        // These game tags are cumulative; duplicate/reordered log lines are not additions.
        totals[metric] = max(totals[metric] ?? 0, total)
        return true
    }

    public func progress(for quest: AccountProgressRecord, quota: Int) -> (total: Int, delta: Int)? {
        // Explicitly verified quest definitions. Never classify arbitrary tasks by text.
        let metric: Metric
        switch (quest.id, quota) {
        case (1032, 20): metric = .heroPowerUses
        case (1035, 500): metric = .manaSpent
        default: return nil
        }
        let delta = totals[metric] ?? 0
        guard matchID != nil, let base = baseline[quest.id],
              base <= Int.max - delta else { return nil }
        return (min(quota, max(quest.progress, base + delta)), delta)
    }

    public mutating func endMatch() { self = AccountQuestEstimate() }
}
