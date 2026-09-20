import Foundation

/// Account snapshots are authoritative replacements. Live values never enter persisted totals.
public struct AccountProgressSession {
    public private(set) var scope: String?
    public private(set) var snapshot: AccountProgressSnapshot?
    public private(set) var matchID: String?
    private var baseline: [Int: Int] = [:]
    private var live: [Int: Int] = [:]

    public init() {}

    public mutating func switchAccount(to scope: String?) {
        guard self.scope != scope else { return }
        self.scope = scope
        snapshot = nil
        matchID = nil
        baseline = [:]
        live = [:]
    }

    public mutating func apply(_ snapshot: AccountProgressSnapshot, scope: String) {
        guard self.scope == scope else { return }
        self.snapshot = snapshot
    }

    public mutating func beginMatch(_ id: String, baseline snapshot: AccountProgressSnapshot) {
        guard scope != nil, !id.isEmpty else { return }
        matchID = id
        baseline = Dictionary(snapshot.achievements.map { ($0.id, $0.progress) }, uniquingKeysWith: { _, last in last })
        live = [:]
    }

    public mutating func updateLive(_ progress: [Int: Int], matchID: String) {
        guard self.matchID == matchID else { return }
        live = progress
    }

    public func delta(for id: Int) -> Int? {
        guard let initial = baseline[id], let current = live[id], current >= initial else { return nil }
        return current - initial
    }

    public func liveTotal(for id: Int) -> Int? {
        guard let current = live[id] else { return nil }
        if let initial = baseline[id], current < initial { return nil }
        return current
    }

    /// Advance only when both stages have authoritative server records. Never invent
    /// a zero-progress next stage or infer completion from an undocumented status enum.
    public func advancedPins(_ pins: Set<Int>) -> Set<Int> {
        guard let snapshot else { return pins }
        let records = Dictionary(snapshot.achievements.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let definitions = Dictionary(snapshot.definitions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return Set(pins.map { initial in
            var current = initial
            var seen: Set<Int> = [initial]
            while let definition = definitions[current], definition.quota > 0,
                  let record = records[current], record.progress >= definition.quota,
                  definition.nextId > 0, records[definition.nextId] != nil {
                guard seen.insert(definition.nextId).inserted else { return initial }
                current = definition.nextId
            }
            return current
        })
    }

    public mutating func invalidateLive() { live = [:] }

    public mutating func endMatch() {
        matchID = nil
        baseline = [:]
        live = [:]
    }
}
