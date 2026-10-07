import Foundation
import XCTest
@testable import ProgressProbeCore

final class AccountQuestEstimateTests: XCTestCase {
    private func state(ids: [Int], track: Int = 1, initial: Int = 0) -> AccountQuestEstimate {
        var state = AccountQuestEstimate()
        state.beginMatch("game", eligible: true, rewardTrack: track)
        state.bind(.init(capturedAt: Date(), quests: ids.map { .init(id: $0, progress: initial, status: 2) },
                         achievements: [], definitions: []), scope: "A")
        return state
    }

    private func delta(_ id: Int, _ state: AccountQuestEstimate, initial: Int = 0) -> Int? {
        guard let rule = AccountQuestEstimate.rules.first(where: { $0.id == id }) else { return nil }
        return state.progress(for: .init(id: id, progress: initial, status: 2), quota: rule.quota)?.delta
    }

    func testCatalogRulesAgreeWithCollectedPrimaryDefinitions() throws {
        struct Catalog: Decodable { let quests: [Definition] }
        struct Definition: Decodable { let id: Int; let quota: Int; let rewardTrackType: Int }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "recurring-quests", withExtension: "json", subdirectory: "Fixtures"))
        let data = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let catalog = Dictionary(uniqueKeysWithValues: data.quests.map { ($0.id, $0) })
        XCTAssertEqual(Set(AccountQuestEstimate.rules.map(\.id)).count, AccountQuestEstimate.rules.count)
        for rule in AccountQuestEstimate.rules {
            let definition = try XCTUnwrap(catalog[rule.id], "Missing quest \(rule.id)")
            XCTAssertEqual(rule.quota, definition.quota, "Quest \(rule.id)")
            XCTAssertEqual(rule.rewardTrack, definition.rewardTrackType, "Quest \(rule.id)")
        }
        // All currently listed traditional objectives that can advance inside a match.
        for id in [85, 91, 92, 83, 84, 90, 82, 26, 80, 1835, 72, 487, 488, 489, 490, 491,
                   492, 493, 69, 70, 433, 76, 24, 1032, 1033, 1697, 1834, 1034, 1035] {
            XCTAssertNotNil(AccountQuestEstimate.rules.first { $0.id == id })
        }
    }

    func testScreenshotObjectivesAndDuplicateActions() {
        var state = state(ids: [1834, 1034, 490, 1037], initial: 2)
        let card = AccountQuestEstimate.CardFacts(type: 5, set: "escapefrom_violet_hold", school: 2, keywords: ["PREPARE"])
        for _ in 0..<2 {
            state.observe(.played(card), eventID: "play:7", matchID: "game", isLocalPlayer: true)
            state.observe(.add(.enemyHeroDamage, 6), eventID: "damage:8", matchID: "game", isLocalPlayer: true)
        }
        XCTAssertEqual(delta(1834, state, initial: 2), 2)
        XCTAssertEqual(delta(490, state, initial: 2), 1)
        XCTAssertEqual(delta(1034, state, initial: 2), 6)
        XCTAssertNil(state.progress(for: .init(id: 1037, progress: 1, status: 2), quota: 5))
        state.observe(.played(card), eventID: "enemy", matchID: "game", isLocalPlayer: false)
        state.observe(.played(card), eventID: "old", matchID: "old", isLocalPlayer: true)
        XCTAssertEqual(delta(1834, state, initial: 2), 2)
    }

    func testAllSpellPairsAndCardTypes() {
        for school in 0...8 {
            var state = state(ids: Array(487...493) + [84])
            state.observe(.played(.init(type: 5, school: school)), eventID: "spell", matchID: "game", isLocalPlayer: true)
            state.observe(.played(.init(type: 4, school: school)), eventID: "minion", matchID: "game", isLocalPlayer: true)
            let pairs = [487: [1, 7], 488: [1, 5], 489: [3, 6], 490: [2, 6], 491: [7, 4], 492: [2, 4], 493: [3, 5]]
            for (id, schools) in pairs { XCTAssertEqual(delta(id, state), schools.contains(school) ? 1 : 0) }
            XCTAssertEqual(delta(84, state), 1)
        }
    }

    func testSummoningAndExpansionBonusesAreDistinctAndNeverQuadrupled() {
        var state = state(ids: [1834, 1835, 1697, 1698, 1550, 1551, 1311, 1312])
        let cards: [AccountQuestEstimate.CardFacts] = [
            .init(type: 4, set: "escapefrom_violet_hold", legendary: true),
            .init(type: 4, set: "cataclysm", races: ["dragon"], keywords: ["HERALD", "SHATTER", "COLOSSAL"]),
            .init(type: 4, set: "time_travel", races: ["beast", "undead"], keywords: ["REWIND"], legendary: true),
            .init(type: 4, set: "the_lost_city", races: ["all"], keywords: ["QUEST", "KINDRED"])
        ]
        for (index, card) in cards.enumerated() {
            state.observe(.played(card), eventID: "play:\(index)", matchID: "game", isLocalPlayer: true)
            state.observe(.summoned(card), eventID: "summon:\(index)", matchID: "game", isLocalPlayer: true)
        }
        XCTAssertEqual(delta(1834, state), 1)
        for id in [1835, 1697, 1698, 1550, 1551, 1311, 1312] { XCTAssertEqual(delta(id, state), 2, "Quest \(id)") }
        state.observe(.summoned(cards[0]), eventID: "resurrect", matchID: "game", isLocalPlayer: true)
        XCTAssertEqual(delta(1835, state), 4)
        XCTAssertEqual(delta(1834, state), 1)
    }

    func testCardCostRacesBattlecryAndMatchModes() {
        let ids = [82, 83, 84, 76, 80, 69, 70, 433, 24, 1033, 386, 396, 397, 398]
        let card = AccountQuestEstimate.CardFacts(type: 4, cost: 10, races: ["all"], keywords: ["BATTLECRY"], golden: true, tier: 6)
        var traditional = state(ids: ids)
        traditional.observe(.played(card), eventID: "1", matchID: "game", isLocalPlayer: true)
        for id in [82, 83, 80, 69, 70, 433, 24, 1033] { XCTAssertEqual(delta(id, traditional), 1) }
        for id in [84, 76] { XCTAssertEqual(delta(id, traditional), 0) }
        for id in [386, 396, 397, 398] { XCTAssertNil(delta(id, traditional)) }
        var bgs = state(ids: ids, track: 2)
        bgs.observe(.played(card), eventID: "1", matchID: "game", isLocalPlayer: true)
        for id in [386, 396, 397, 398] { XCTAssertEqual(delta(id, bgs), 1) }
        XCTAssertNil(delta(1033, bgs))
        XCTAssertNil(traditional.progress(for: .init(id: 1033, progress: 0, status: 2), quota: 50, rewardTrack: 2))
    }

    func testAssignmentRemovalResetAndOverflowFailSafely() {
        for replacement in [[], [AccountProgressRecord(id: 1034, progress: 1, status: 2)],
                            [.init(id: 1034, progress: 10, status: 6)]] {
            var state = state(ids: [1034], initial: 10)
            state.observe(.add(.enemyHeroDamage, Int.max), eventID: "hit", matchID: "game", isLocalPlayer: true)
            XCTAssertEqual(state.progress(for: .init(id: 1034, progress: 10, status: 2), quota: 200)?.total, 200)
            state.bind(.init(capturedAt: Date(), quests: replacement, achievements: [], definitions: []), scope: "A")
            XCTAssertNil(state.progress(for: .init(id: 1034, progress: 10, status: 2), quota: 200))
        }
    }

    private let hero = AccountProgressRecord(id: 1032, progress: 8, status: 2)
    private let mana = AccountProgressRecord(id: 1035, progress: 169, status: 2)
    private var snapshot: AccountProgressSnapshot {
        AccountProgressSnapshot(capturedAt: Date(), quests: [hero, mana], achievements: [], definitions: [])
    }

    func testCumulativeOwnTagsUpdateIndependentlyAndDoNotDoubleCount() {
        var state = AccountQuestEstimate()
        state.beginMatch("game", eligible: true)
        state.bind(snapshot, scope: "A")
        state.observe(.heroPowerUses, total: 1, matchID: "game", isLocalPlayer: true)
        state.observe(.manaSpent, total: 2, matchID: "game", isLocalPlayer: true)
        XCTAssertEqual(state.progress(for: hero, quota: 20)?.total, 9)
        XCTAssertEqual(state.progress(for: mana, quota: 500)?.total, 171)
        state.observe(.manaSpent, total: 2, matchID: "game", isLocalPlayer: true)
        state.observe(.manaSpent, total: 1, matchID: "game", isLocalPlayer: true)
        state.observe(.manaSpent, total: 6, matchID: "game", isLocalPlayer: true)
        XCTAssertEqual(state.progress(for: mana, quota: 500)?.total, 175)
        XCTAssertEqual(state.progress(for: mana, quota: 500)?.delta, 6)
        XCTAssertEqual(mana.progress, 169)
    }

    func testRejectOpponentSpectatorAndOldMatchEvents() {
        var state = AccountQuestEstimate()
        state.beginMatch("game", eligible: false)
        state.bind(snapshot, scope: "A")
        state.observe(.manaSpent, total: 10, matchID: "game", isLocalPlayer: true)
        XCTAssertNil(state.progress(for: mana, quota: 500))
        state.beginMatch("game", eligible: true)
        state.bind(snapshot, scope: "A")
        state.observe(.manaSpent, total: 10, matchID: "game", isLocalPlayer: false)
        state.observe(.manaSpent, total: 10, matchID: "old", isLocalPlayer: true)
        XCTAssertEqual(state.progress(for: mana, quota: 500)?.delta, 0)
        XCTAssertEqual(state.progress(for: mana, quota: 500)?.total, 169)
    }

    func testNoEstimateWithoutBaselineOrForUnknownQuestDefinition() {
        var state = AccountQuestEstimate()
        state.beginMatch("game", eligible: true)
        state.observe(.heroPowerUses, total: 2, matchID: "game", isLocalPlayer: true)
        XCTAssertNil(state.progress(for: hero, quota: 20))
        state.bind(snapshot, scope: "A")
        XCTAssertEqual(state.progress(for: hero, quota: 20)?.total, 10)
        XCTAssertNil(state.progress(for: hero, quota: 50))
        XCTAssertNil(state.progress(for: .init(id: 443, progress: 0, status: 2), quota: 3))
    }

    func testSnapshotRefreshDoesNotRebaseAndMatchEndDiscardsEstimate() {
        var state = AccountQuestEstimate()
        state.beginMatch("game", eligible: true)
        state.bind(snapshot, scope: "A")
        state.observe(.manaSpent, total: 6, matchID: "game", isLocalPlayer: true)
        let confirmed = AccountProgressRecord(id: 1035, progress: 175, status: 2)
        state.bind(AccountProgressSnapshot(capturedAt: Date(), quests: [confirmed], achievements: [], definitions: []), scope: "A")
        XCTAssertEqual(state.progress(for: confirmed, quota: 500)?.total, 175)
        state.endMatch()
        XCTAssertNil(state.progress(for: confirmed, quota: 500))
        state.observe(.manaSpent, total: 20, matchID: "game", isLocalPlayer: true)
        XCTAssertNil(state.progress(for: confirmed, quota: 500))
    }

    func testAccountSwitchClearsEstimatesAndQuotaCapsDisplay() {
        var state = AccountQuestEstimate()
        state.beginMatch("game", eligible: true)
        state.bind(snapshot, scope: "A")
        state.observe(.heroPowerUses, total: 20, matchID: "game", isLocalPlayer: true)
        XCTAssertEqual(state.progress(for: hero, quota: 20)?.total, 20)
        state.bind(snapshot, scope: "B")
        XCTAssertNil(state.matchID)
        XCTAssertNil(state.progress(for: hero, quota: 20))
    }
}
