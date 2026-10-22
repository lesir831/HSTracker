import Foundation

/// Non-persisted log estimates. Server snapshots remain the persisted source of truth.
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
        case destroyed(CardFacts)
        case deathrattleTriggered(CardFacts)
        /// Base draw/mana credit comes from the cumulative tags; these carry
        /// only the per-card expansion bonus, so the base is never counted twice.
        case drawn(CardFacts)
        case manaSpentOn(CardFacts, Int)
        case statsIncreased
        case handFilled
        case damageTaken(Int, ownTurn: Bool)
        case attacked(CardFacts, Int)
        case discovered(CardFacts)
        case matchCompleted(won: Bool)
    }

    /// Match facts captured on the log queue, not inferred from quest text or
    /// the class of a generated/stolen card. Class bonuses use the player's hero.
    public struct Context {
        public let ranked: Bool
        public let playerClass: String
        public let tavernBrawl: Bool

        public init(ranked: Bool = false, playerClass: String = "", tavernBrawl: Bool = false) {
            self.ranked = ranked
            self.playerClass = playerClass
            self.tavernBrawl = tavernBrawl
        }
    }

    public struct EventRule {
        public let id: Int
        public let quota: Int
        let credit: (Event, Context) -> Int
    }

    /// Current event definitions checked against the client and public catalog
    /// on 2026-10-07. These are explicit rules, never parsed localized prose.
    /// Event bonuses are additive; ordinary quests' double-credit rules differ.
    public static let eventRules: [EventRule] = [
        EventRule(id: 1956, quota: 350) { event, context in
            guard case .played(let card) = event, card.type == 5 else { return 0 }
            return 1 + (context.ranked ? 1 : 0) + (card.school == 6 ? 1 : 0)
                + (context.playerClass == "warlock" ? 1 : 0)
        },
        EventRule(id: 1957, quota: 60) { event, context in
            guard case .matchCompleted(let won) = event else { return 0 }
            return 1 + (context.tavernBrawl ? 3 : 0) + (won ? 1 : 0)
        },
        EventRule(id: 1986, quota: 50) { event, context in
            guard case .summoned(let card) = event, card.type == 4 else { return 0 }
            return 1 + (context.ranked ? 1 : 0) + (card.keywords.contains("DEATHRATTLE") ? 1 : 0)
        },
        EventRule(id: 1987, quota: 50) { event, context in
            switch event {
            case .add(.cardsDrawn, let count): return multiply(max(0, count), by: context.ranked ? 2 : 1)
            case .drawn(let card): return card.set == "escapefrom_violet_hold" ? 1 : 0
            default: return 0
            }
        },
        EventRule(id: 1988, quota: 30) { event, context in
            guard case .statsIncreased = event else { return 0 }
            return context.ranked ? 2 : 1
        },
        EventRule(id: 1989, quota: 15) { event, context in
            guard case .played(let card) = event, card.type == 39 else { return 0 }
            return 1 + (context.ranked ? 1 : 0) + (card.set == "escapefrom_violet_hold" ? 1 : 0)
        },
        EventRule(id: 1990, quota: 100) { event, context in
            switch event {
            case .add(.manaSpent, let count): return multiply(max(0, count), by: context.ranked ? 2 : 1)
            case .manaSpentOn(let card, let count): return card.set == "escapefrom_violet_hold" ? max(0, count) : 0
            default: return 0
            }
        },
        EventRule(id: 1991, quota: 1) { event, _ in
            guard case .played(let card) = event else { return 0 }
            return card.cost == 10 ? 1 : 0
        },
        EventRule(id: 1992, quota: 1) { event, _ in
            if case .handFilled = event { return 1 }
            return 0
        },
        EventRule(id: 1993, quota: 50) { event, context in
            guard case .add(.turnsTaken, let count) = event else { return 0 }
            return multiply(max(0, count), by: context.ranked ? 2 : 1)
        },
        EventRule(id: 1994, quota: 15) { event, context in
            guard case .add(.heroPowerUses, let count) = event else { return 0 }
            return multiply(max(0, count), by: context.ranked ? 2 : 1)
        },
        EventRule(id: 1995, quota: 75) { event, context in
            guard case .damageTaken(let count, let ownTurn) = event else { return 0 }
            return multiply(max(0, count), by: 1 + (context.ranked ? 1 : 0) + (ownTurn ? 1 : 0))
        },
        EventRule(id: 1996, quota: 75) { event, context in
            guard case .destroyed(let card) = event, card.type == 4 else { return 0 }
            return 1 + (context.ranked ? 1 : 0) + (card.set == "escapefrom_violet_hold" ? 1 : 0)
        },
        EventRule(id: 1997, quota: 75) { event, context in
            guard case .attacked(let card, let count) = event else { return 0 }
            return multiply(max(0, count), by: 1 + (context.ranked ? 1 : 0)
                + (context.playerClass == "rogue" ? 1 : 0) + (card.set == "escapefrom_violet_hold" ? 1 : 0))
        },
        EventRule(id: 1998, quota: 25) { event, context in
            guard case .deathrattleTriggered(let card) = event else { return 0 }
            return 1 + (context.ranked ? 1 : 0) + (card.set == "escapefrom_violet_hold" ? 1 : 0)
        },
        EventRule(id: 1999, quota: 20) { event, context in
            guard case .discovered(let card) = event else { return 0 }
            return 1 + (context.ranked ? 1 : 0) + (card.set == "escapefrom_violet_hold" ? 1 : 0)
        }
    ]

    private static func multiply(_ value: Int, by multiplier: Int) -> Int {
        value > Int.max / multiplier ? Int.max : value * multiplier
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
    private var eventTotals: [Int: Int] = [:]
    private var eventIDs: Set<String> = []
    private var rewardTrack = 1
    private var awaitingCompletedEventSettlement = false

    public init() {}

    public mutating func beginMatch(_ id: String, eligible: Bool, rewardTrack: Int = 1) {
        self = AccountQuestEstimate()
        self.rewardTrack = rewardTrack
        if eligible && !id.isEmpty { matchID = id }
    }

    public mutating func bind(_ snapshot: AccountProgressSnapshot, scope: String) {
        if awaitingCompletedEventSettlement {
            // The first post-game authoritative read may also correct an
            // ineligible concession. Never persist or carry this into a new match.
            self = AccountQuestEstimate()
            return
        }
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
    public mutating func observe(_ event: Event, eventID: String, matchID: String, isLocalPlayer: Bool,
                                 context: Context = Context()) -> Bool {
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
        case .destroyed, .deathrattleTriggered, .drawn, .manaSpentOn, .statsIncreased,
             .handFilled, .damageTaken, .attacked, .discovered, .matchCompleted: break
        }
        observeEvent(event, context: context)
        return true
    }

    private mutating func observeEvent(_ event: Event, context: Context) {
        // A reward-track-7 task does not make Battlegrounds actions eligible
        // for a Traditional Modes objective.
        guard rewardTrack == 1 else { return }
        for rule in Self.eventRules {
            let amount = rule.credit(event, context)
            if amount > 0 { eventTotals[rule.id] = Self.add(eventTotals[rule.id] ?? 0, amount) }
        }
    }

    private static func add(_ a: Int, _ b: Int) -> Int { a > Int.max - b ? Int.max : a + b }

    @discardableResult
    public mutating func observe(_ metric: Metric, total: Int, matchID: String, isLocalPlayer: Bool,
                                 context: Context = Context()) -> Bool {
        guard self.matchID == matchID, isLocalPlayer, total > (totals[metric] ?? 0) else { return false }
        observeEvent(.add(metric, total - (totals[metric] ?? 0)), context: context)
        // These game tags are cumulative; duplicate/reordered log lines are not additions.
        totals[metric] = max(totals[metric] ?? 0, total)
        return true
    }

    public func progress(for quest: AccountProgressRecord, quota: Int, rewardTrack: Int? = nil,
                         isEvent: Bool = false) -> (total: Int, delta: Int)? {
        guard matchID != nil || awaitingCompletedEventSettlement,
              let base = baseline[quest.id], !(3...9).contains(quest.status) else { return nil }
        if isEvent || rewardTrack == 7 {
            guard self.rewardTrack == 1, rewardTrack == 7,
                  Self.eventRules.contains(where: { $0.id == quest.id && $0.quota == quota }) else { return nil }
            let delta = eventTotals[quest.id] ?? 0
            return (min(quota, max(quest.progress, Self.add(base, delta))), delta)
        }
        guard rewardTrack == nil || rewardTrack == self.rewardTrack else { return nil }
        guard let rule = Self.rules.first(where: { $0.id == quest.id && $0.quota == quota && $0.rewardTrack == self.rewardTrack }) else { return nil }
        let delta = rule.metric.map { totals[$0] ?? 0 } ?? cardTotals[quest.id] ?? 0
        return (min(quota, max(quest.progress, Self.add(base, delta))), delta)
    }

    public mutating func endMatch(preservingCompletedEvent: Bool = false) {
        guard preservingCompletedEvent, baseline[1957] != nil, (eventTotals[1957] ?? 0) > 0 else {
            self = AccountQuestEstimate()
            return
        }
        matchID = nil
        awaitingCompletedEventSettlement = true
        baseline = baseline.filter { $0.key == 1957 }
        eventTotals = eventTotals.filter { $0.key == 1957 }
        totals.removeAll()
        cardTotals.removeAll()
        eventIDs.removeAll()
    }
}
