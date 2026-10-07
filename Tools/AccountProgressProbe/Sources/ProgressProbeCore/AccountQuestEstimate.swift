import Foundation

/// Per-match estimates only. Server snapshots remain the persisted source of truth.
public struct AccountQuestEstimate {
    public enum Metric: String {
        case heroPowerUses, manaSpent, enemyHeroDamage, cardsDrawn, turnsTaken
        case minionsDestroyed, deathrattles, cardsBought, tavernUpgrades, divineShields
    }

    /// Immutable facts copied on the log queue. Keywords are actual card tags,
    /// not words in localized text or ReferencedTags (e.g. Brann is not a Battlecry).
    public struct CardFacts {
        public var type: Int
        public var cost: Int
        public var set: String
        public var races: Set<String>
        public var school: Int
        public var keywords: Set<String>
        public var legendary: Bool
        public var golden: Bool
        public var tier: Int

        public init(type: Int, cost: Int = 0, set: String = "", races: Set<String> = [],
                    school: Int = 0, keywords: Set<String> = [], legendary: Bool = false,
                    golden: Bool = false, tier: Int = 0) {
            self.type = type
            self.cost = cost
            self.set = set
            self.races = races
            self.school = school
            self.keywords = keywords
            self.legendary = legendary
            self.golden = golden
            self.tier = tier
        }

        func hasRace(_ choices: Set<String>) -> Bool {
            !races.isDisjoint(with: choices) || races.contains("all")
        }
    }

    public enum Event {
        case add(Metric, Int)
        case played(CardFacts)
        case summoned(CardFacts)
    }

    public struct Rule {
        public let id: Int
        public let quota: Int
        public let rewardTrack: Int
        let metric: Metric?
        let cardCredit: ((CardFacts, Bool) -> Int)?
    }

    /// Verified ID/quota pairs from the public client catalog, 2026-09-23.
    /// Cadence and assignment still come from native account metadata. A catalog
    /// entry alone never makes a quest visible. See Tools/AccountProgressProbe/QUESTS.md.
    public static let rules: [Rule] = {
        var result: [Rule] = []
        func metric(_ ids: [(Int, Int)], _ metric: Metric, track: Int = 1) {
            result += ids.map { Rule(id: $0.0, quota: $0.1, rewardTrack: track, metric: metric, cardCredit: nil) }
        }
        func played(_ ids: [(Int, Int)], track: Int = 1, _ predicate: @escaping (CardFacts) -> Bool) {
            result += ids.map { Rule(id: $0.0, quota: $0.1, rewardTrack: track, metric: nil,
                                    cardCredit: { card, summoned in !summoned && predicate(card) ? 1 : 0 }) }
        }
        func expansion(_ id: Int, _ quota: Int, _ set: String, summoned: Bool = false,
                       bonus: @escaping (CardFacts) -> Bool) {
            result.append(Rule(id: id, quota: quota, rewardTrack: 1, metric: nil, cardCredit: { card, isSummon in
                guard summoned == isSummon, card.set == set, !summoned || card.type == 4 else { return 0 }
                return bonus(card) ? 2 : 1 // A card satisfying two bonus conditions still counts twice.
            }))
        }
        metric([(85, 5), (28, 30), (1032, 20)], .heroPowerUses)
        metric([(93, 650), (1035, 500)], .manaSpent)
        metric([(26, 65), (89, 400), (903, 80), (923, 80), (924, 80), (925, 80), (1034, 200)], .enemyHeroDamage)
        metric([(90, 30)], .cardsDrawn)
        metric([(91, 20)], .turnsTaken)
        metric([(92, 25)], .minionsDestroyed)
        metric([(72, 10)], .deathrattles)
        played([(82, 30)]) { _ in true }
        played([(83, 25)]) { $0.type == 4 }
        played([(84, 25)]) { $0.type == 5 }
        played([(24, 50), (68, 20), (71, 75), (1033, 50)]) { $0.keywords.contains("BATTLECRY") }
        played([(23, 10)]) { $0.type == 4 && $0.hasRace(["murloc"]) }
        played([(69, 12)]) { $0.type == 4 && $0.hasRace(["beast"]) }
        played([(70, 12)]) { $0.type == 4 && $0.hasRace(["dragon"]) }
        played([(433, 12)]) { $0.type == 4 && $0.hasRace(["undead"]) }
        played([(74, 4)]) { $0.type == 7 }
        played([(75, 6)]) { $0.cost >= 7 }
        played([(76, 25), (81, 50)]) { $0.cost <= 3 }
        played([(77, 10)]) { $0.cost % 2 == 1 }
        played([(78, 10)]) { $0.cost % 2 == 0 }
        played([(79, 8)]) { $0.type == 4 && $0.cost == 1 }
        played([(80, 1)]) { $0.cost == 10 }
        for (id, schools) in [(487, [1, 7]), (488, [1, 5]), (489, [3, 6]), (490, [2, 6]),
                              (491, [7, 4]), (492, [2, 4]), (493, [3, 5])] {
            played([(id, 12)]) { $0.type == 5 && schools.contains($0.school) }
        }
        expansion(1311, 75, "the_lost_city") { !$0.keywords.isDisjoint(with: ["QUEST", "QUESTLINE", "KINDRED"]) }
        expansion(1312, 10, "the_lost_city", summoned: true) { $0.hasRace(["beast", "elemental", "murloc"]) }
        expansion(1550, 75, "time_travel") { $0.legendary || $0.keywords.contains("REWIND") }
        expansion(1551, 10, "time_travel", summoned: true) { $0.hasRace(["beast", "dragon", "undead"]) }
        expansion(1697, 75, "cataclysm") { !$0.keywords.isDisjoint(with: ["HERALD", "SHATTER", "SHATTERED"]) }
        expansion(1698, 10, "cataclysm", summoned: true) { $0.hasRace(["dragon"]) || $0.keywords.contains("COLOSSAL") }
        expansion(1834, 75, "escapefrom_violet_hold") { $0.keywords.contains("PREPARE") }
        expansion(1835, 10, "escapefrom_violet_hold", summoned: true) { $0.legendary }

        metric([(380, 150)], .enemyHeroDamage, track: 2)
        metric([(382, 500)], .minionsDestroyed, track: 2)
        metric([(383, 100)], .cardsBought, track: 2)
        metric([(394, 60)], .deathrattles, track: 2)
        metric([(395, 40)], .divineShields, track: 2)
        metric([(399, 30)], .tavernUpgrades, track: 2)
        for (id, races) in [(386, ["beast", "naga"]), (387, ["demon", "elemental"]),
                            (388, ["elemental", "beast"]), (389, ["mechanical", "pirate"]),
                            (390, ["murloc", "demon"]), (391, ["naga", "dragon"]),
                            (392, ["pirate", "quilboar"]), (393, ["murloc", "quilboar"]),
                            (494, ["beast", "undead"]), (495, ["murloc", "undead"])] {
            played([(id, 30)], track: 2) { $0.type == 4 && $0.hasRace(Set(races)) }
        }
        played([(396, 40)], track: 2) { $0.type == 4 && $0.keywords.contains("BATTLECRY") }
        played([(397, 10)], track: 2) { $0.type == 4 && $0.golden }
        played([(398, 10)], track: 2) { $0.type == 4 && $0.tier == 6 }
        return result
    }()

    public private(set) var matchID: String?
    public var hasBaseline: Bool { scope != nil }
    private var scope: String?
    private var baseline: [Int: Int] = [:]
    private var totals: [Metric: Int] = [:]
    private var cardTotals: [Int: Int] = [:]
    private var eventIDs: Set<String> = []
    private var rewardTrack = 1

    public init() {}

    public mutating func beginMatch(_ id: String, eligible: Bool, rewardTrack: Int = 1) {
        self = AccountQuestEstimate()
        self.rewardTrack = rewardTrack
        if eligible && !id.isEmpty { matchID = id }
    }

    public mutating func bind(_ snapshot: AccountProgressSnapshot, scope: String) {
        guard matchID != nil else { return }
        if let previous = self.scope {
            if previous != scope { self = AccountQuestEstimate() }
            else {
                // Removal, reroll/reset or a decreased authoritative total means
                // this is no longer the assignment whose opening total we captured.
                let current = Dictionary(snapshot.quests.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                baseline = baseline.filter { id, base in
                    guard let quest = current[id] else { return false }
                    return quest.progress >= base && !(4...9).contains(quest.status)
                }
            }
            return // Never add a match total to a newer, partially updated baseline.
        }
        self.scope = scope
        baseline = Dictionary(snapshot.quests.map { ($0.id, $0.progress) }, uniquingKeysWith: { _, last in last })
    }

    /// Additive actions use a parser-owned identity (block/entity/transition),
    /// separate from cumulative player tags. Replayed notifications cannot add twice.
    @discardableResult
    public mutating func observe(_ event: Event, eventID: String, matchID: String, isLocalPlayer: Bool) -> Bool {
        guard self.matchID == matchID, isLocalPlayer, !eventID.isEmpty,
              eventIDs.insert(eventID).inserted else { return false }
        switch event {
        case .add(let metric, let amount):
            guard amount > 0 else { return false }
            totals[metric] = Self.add(totals[metric] ?? 0, amount)
        case .played(let card), .summoned(let card):
            let summoned: Bool
            if case .summoned = event { summoned = true } else { summoned = false }
            for rule in Self.rules where rule.rewardTrack == rewardTrack {
                let amount = rule.cardCredit?(card, summoned) ?? 0
                if amount > 0 { cardTotals[rule.id] = Self.add(cardTotals[rule.id] ?? 0, amount) }
            }
        }
        return true
    }

    private static func add(_ a: Int, _ b: Int) -> Int { a > Int.max - b ? Int.max : a + b }

    @discardableResult
    public mutating func observe(_ metric: Metric, total: Int, matchID: String, isLocalPlayer: Bool) -> Bool {
        guard self.matchID == matchID, isLocalPlayer, total > (totals[metric] ?? 0) else { return false }
        // These game tags are cumulative; duplicate/reordered log lines are not additions.
        totals[metric] = max(totals[metric] ?? 0, total)
        return true
    }

    public func progress(for quest: AccountProgressRecord, quota: Int, rewardTrack: Int? = nil) -> (total: Int, delta: Int)? {
        guard rewardTrack == nil || rewardTrack == self.rewardTrack else { return nil }
        guard let rule = Self.rules.first(where: { $0.id == quest.id && $0.quota == quota && $0.rewardTrack == self.rewardTrack }),
              matchID != nil, let base = baseline[quest.id], !(3...9).contains(quest.status) else { return nil }
        let delta = rule.metric.map { totals[$0] ?? 0 } ?? cardTotals[quest.id] ?? 0
        return (min(quota, max(quest.progress, Self.add(base, delta))), delta)
    }

    public mutating func endMatch() { self = AccountQuestEstimate() }
}
