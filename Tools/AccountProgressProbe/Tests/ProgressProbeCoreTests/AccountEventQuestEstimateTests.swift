import Foundation
import XCTest
@testable import ProgressProbeCore

final class AccountEventQuestEstimateTests: XCTestCase {
    private let rankedWarlock = AccountQuestEstimate.Context(ranked: true, playerClass: "warlock")

    private func snapshot(_ ids: [Int], initial: Int = 0) -> AccountProgressSnapshot {
        .init(capturedAt: Date(), quests: ids.map { .init(id: $0, progress: initial, status: 2) },
              achievements: [], definitions: [])
    }

    private func state(track: Int = 1) -> AccountQuestEstimate {
        var result = AccountQuestEstimate()
        result.beginMatch("match", eligible: true, rewardTrack: track)
        result.bind(snapshot(AccountQuestEstimate.eventRules.map(\.id), initial: 2), scope: "A")
        return result
    }

    private func progress(_ id: Int, _ state: AccountQuestEstimate, confirmed: Int = 2) -> (total: Int, delta: Int)? {
        let quota = AccountQuestEstimate.eventRules.first { $0.id == id }!.quota
        return state.progress(for: .init(id: id, progress: confirmed, status: 2), quota: quota, rewardTrack: 7, isEvent: true)
    }

    func testEveryCurrentEventDefinitionHasAnExactRule() throws {
        struct Catalog: Decodable { let quests: [Definition] }
        struct Definition: Decodable { let id: Int; let quota: Int; let rewardTrackType: Int }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "event-quests-20261007", withExtension: "json", subdirectory: "Fixtures"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).quests
        XCTAssertEqual(catalog.count, 16)
        XCTAssertEqual(Set(AccountQuestEstimate.eventRules.map(\.id)), Set(catalog.map(\.id)))
        for rule in AccountQuestEstimate.eventRules {
            let definition = try XCTUnwrap(catalog.first { $0.id == rule.id })
            XCTAssertEqual(rule.quota, definition.quota)
            XCTAssertEqual(definition.rewardTrackType, 7)
        }
        var state = state()
        state.endMatch()
        state.beginMatch("match", eligible: true)
        state.bind(snapshot(catalog.map(\.id)), scope: "A")
        for id in catalog.map(\.id) {
            let quota = try XCTUnwrap(catalog.first { $0.id == id }).quota
            XCTAssertEqual(state.progress(for: .init(id: id, progress: 0, status: 2), quota: quota, rewardTrack: 7)?.delta, 0)
        }
    }

    func testRemainingEightObjectivesAndBonusesHaveIndependentCounters() {
        var state = state()
        let violet = AccountQuestEstimate.CardFacts(type: 4, set: "escapefrom_violet_hold")
        let context = AccountQuestEstimate.Context(ranked: true, playerClass: "rogue", tavernBrawl: false)
        let events: [AccountQuestEstimate.Event] = [.add(.cardsDrawn, 2), .drawn(violet), .statsIncreased,
            .manaSpentOn(violet, 3), .handFilled, .damageTaken(5, ownTurn: true),
            .damageTaken(2, ownTurn: false), .attacked(violet, 2), .discovered(violet), .discovered(.init(type: 5))]
        for (index, event) in events.enumerated() {
            for _ in 0..<2 {
                state.observe(event, eventID: "action:\(index)", matchID: "match", isLocalPlayer: true, context: context)
            }
        }
        for total in [3, 3, 2, 5] {
            state.observe(.manaSpent, total: total, matchID: "match", isLocalPlayer: true, context: context)
        }
        for (id, expected) in [(1987, 5), (1988, 2), (1990, 13), (1992, 1), (1995, 19), (1997, 8), (1999, 5)] {
            XCTAssertEqual(progress(id, state)?.delta, expected, "Quest \(id)")
        }
        XCTAssertEqual(progress(1957, state)?.delta, 0) // Playing actions is not completing a game.
        state.observe(.matchCompleted(won: true), eventID: "result", matchID: "match", isLocalPlayer: true,
            context: .init(tavernBrawl: true))
        XCTAssertEqual(progress(1957, state)?.delta, 5)
        for id in [1956, 1986, 1989, 1991, 1993, 1994, 1996, 1998] {
            XCTAssertEqual(progress(id, state)?.delta, 0, "Unrelated quest \(id)")
        }
    }

    func testNewBonusesWithoutRankedAndOverflow() {
        var state = state()
        for (index, event) in [AccountQuestEstimate.Event.add(.cardsDrawn, 1), .statsIncreased,
                              .damageTaken(4, ownTurn: false), .attacked(.init(type: 3), 1),
                              .discovered(.init(type: 4)), .matchCompleted(won: false)].enumerated() {
            state.observe(event, eventID: "action:\(index)", matchID: "match", isLocalPlayer: true)
        }
        for (id, expected) in [(1957, 1), (1987, 1), (1988, 1), (1995, 4), (1997, 1), (1999, 1)] {
            XCTAssertEqual(progress(id, state)?.delta, expected)
        }
        state.observe(.damageTaken(Int.max, ownTurn: true), eventID: "overflow", matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        XCTAssertEqual(progress(1995, state)?.total, 75)
        XCTAssertEqual(progress(1995, state)?.delta, Int.max)
    }

    func testFinishedMatchEstimateSurvivesUntilAuthoritativeReadOnly() {
        var state = state()
        for _ in 0..<2 {
            state.observe(.matchCompleted(won: true), eventID: "match-result", matchID: "match", isLocalPlayer: true, context: .init(tavernBrawl: true))
        }
        state.endMatch(preservingCompletedEvent: true)
        XCTAssertNil(state.matchID)
        XCTAssertEqual(progress(1957, state)?.total, 7)
        XCTAssertEqual(progress(1957, state)?.delta, 5)
        XCTAssertNil(progress(1987, state))
        XCTAssertFalse(state.observe(.matchCompleted(won: true), eventID: "late", matchID: "match", isLocalPlayer: true))
        // Server can award a smaller amount, or reject an early concession.
        state.bind(snapshot([1957], initial: 2), scope: "A")
        XCTAssertNil(progress(1957, state))
        state.beginMatch("next", eligible: true)
        state.bind(snapshot([1957], initial: 7), scope: "A")
        XCTAssertEqual(progress(1957, state, confirmed: 7)?.delta, 0)
    }

    func testSpellBonusesAreAdditiveAndDoNotCountSummonsOrHeroPowers() {
        for ranked in [false, true] {
            for hero in ["mage", "warlock"] {
                for school in [2, 6] {
                    var state = state()
                    let context = AccountQuestEstimate.Context(ranked: ranked, playerClass: hero)
                    let spell = AccountQuestEstimate.CardFacts(type: 5, school: school)
                    state.observe(.played(spell), eventID: "spell", matchID: "match", isLocalPlayer: true, context: context)
                    state.observe(.played(spell), eventID: "spell", matchID: "match", isLocalPlayer: true, context: context)
                    state.observe(.played(.init(type: 10, school: school)), eventID: "power", matchID: "match", isLocalPlayer: true, context: context)
                    state.observe(.summoned(spell), eventID: "invalid", matchID: "match", isLocalPlayer: true, context: context)
                    let credit = 1 + (ranked ? 1 : 0) + (hero == "warlock" ? 1 : 0) + (school == 6 ? 1 : 0)
                    XCTAssertEqual(progress(1956, state)?.delta, credit)
                    XCTAssertEqual(progress(1956, state)?.total, 2 + credit)
                }
            }
        }
    }

    func testSummonsCountGeneratedMinionsAndDeathrattleButNotPlaysOrTriggers() {
        var state = state()
        let minion = AccountQuestEstimate.CardFacts(type: 4, keywords: ["DEATHRATTLE"])
        for (id, event) in [AccountQuestEstimate.Event.played(minion), .summoned(minion),
                            .summoned(.init(type: 4)), .deathrattleTriggered(minion)].enumerated() {
            state.observe(event, eventID: "action:\(id)", matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        }
        XCTAssertEqual(progress(1986, state)?.delta, 5) // 3 + 2; playing does not double-count the summon.
        XCTAssertEqual(progress(1998, state)?.delta, 2)
    }

    func testRelatedEventObjectivesUseTheirOwnSourceAndCumulativeIncrements() {
        var state = state()
        for (id, event) in [AccountQuestEstimate.Event.played(.init(type: 39, cost: 10, set: "escapefrom_violet_hold")),
                            .destroyed(.init(type: 4, set: "escapefrom_violet_hold")),
                            .deathrattleTriggered(.init(type: 4, set: "escapefrom_violet_hold")),
                            .add(.turnsTaken, 1)].enumerated() {
            state.observe(event, eventID: "event:\(id)", matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        }
        for total in [1, 1, 0, 3, 2] {
            state.observe(.heroPowerUses, total: total, matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        }
        for (id, expected) in [(1989, 3), (1991, 1), (1993, 2), (1994, 6), (1996, 3), (1998, 3)] {
            XCTAssertEqual(progress(id, state)?.delta, expected)
        }
        state.observe(.heroPowerUses, total: Int.max, matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        XCTAssertEqual(progress(1994, state)?.delta, Int.max)
        XCTAssertEqual(progress(1994, state)?.total, 15)
    }

    func testEventIdentityQuotaModeAndParticipantAreRequired() {
        let spell = AccountQuestEstimate.Event.played(.init(type: 5, school: 6))
        var state = state()
        XCTAssertFalse(state.observe(spell, eventID: "opponent", matchID: "match", isLocalPlayer: false, context: rankedWarlock))
        XCTAssertFalse(state.observe(spell, eventID: "old", matchID: "old", isLocalPlayer: true, context: rankedWarlock))
        XCTAssertEqual(progress(1956, state)?.delta, 0)
        let quest = AccountProgressRecord(id: 1956, progress: 2, status: 2)
        XCTAssertNil(state.progress(for: quest, quota: 350, rewardTrack: 1))
        XCTAssertNil(state.progress(for: quest, quota: 351, rewardTrack: 7))
        XCTAssertNil(state.progress(for: .init(id: 1032, progress: 0, status: 2), quota: 20, rewardTrack: 1, isEvent: true))
        var battlegrounds = self.state(track: 2)
        battlegrounds.observe(spell, eventID: "spell", matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        XCTAssertNil(progress(1956, battlegrounds))
        var spectator = AccountQuestEstimate()
        spectator.beginMatch("match", eligible: false)
        spectator.bind(snapshot([1956]), scope: "A")
        XCTAssertNil(progress(1956, spectator))
    }

    func testRefreshSettlementChainRemovalAndAccountChangeDoNotReuseEstimates() {
        var state = state()
        state.observe(.played(.init(type: 5, school: 6)), eventID: "spell", matchID: "match", isLocalPlayer: true, context: rankedWarlock)
        state.bind(snapshot([1956], initial: 6), scope: "A")
        XCTAssertEqual(progress(1956, state, confirmed: 6)?.total, 6)
        XCTAssertEqual(progress(1956, state, confirmed: 9)?.total, 9)
        XCTAssertNil(state.progress(for: .init(id: 1956, progress: 350, status: 3), quota: 350, rewardTrack: 7))
        state.bind(snapshot([1986]), scope: "A")
        XCTAssertNil(progress(1956, state))
        XCTAssertNil(progress(1986, state)) // A new chain step cannot inherit an earlier match's actions.
        state = self.state()
        state.bind(snapshot([1956]), scope: "B")
        XCTAssertNil(progress(1956, state))
        state = self.state()
        state.endMatch()
        XCTAssertNil(progress(1956, state))
    }
}
