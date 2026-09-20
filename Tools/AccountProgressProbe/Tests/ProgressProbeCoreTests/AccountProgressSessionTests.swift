import Foundation
import XCTest
@testable import ProgressProbeCore

final class AccountProgressSessionTests: XCTestCase {
    private func snapshot(_ values: [(Int, Int)], definitions: [AccountAchievementDefinition] = []) -> AccountProgressSnapshot {
        AccountProgressSnapshot(capturedAt: Date(), quests: [],
            achievements: values.map { AccountProgressRecord(id: $0.0, progress: $0.1, status: 0) },
            definitions: definitions)
    }

    func testAccountSwitchRejectsOldSnapshotAndClearsLive() {
        var session = AccountProgressSession()
        session.switchAccount(to: "A")
        let first = snapshot([(1, 8)])
        session.apply(first, scope: "A")
        session.beginMatch("game", baseline: first)
        session.updateLive([1: 12], matchID: "game")
        session.switchAccount(to: "B")
        session.apply(first, scope: "A")
        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.matchID)
        XCTAssertNil(session.delta(for: 1))
        XCTAssertNil(session.liveTotal(for: 1))
    }

    func testCumulativeValuesAreNeverAddedToSnapshot() {
        var session = AccountProgressSession()
        session.switchAccount(to: "A")
        let first = snapshot([(1, 8)])
        session.apply(first, scope: "A")
        session.beginMatch("game", baseline: first)
        session.updateLive([1: 12], matchID: "game")
        session.updateLive([1: 12], matchID: "game")
        XCTAssertEqual(session.delta(for: 1), 4)
        XCTAssertEqual(session.snapshot?.achievements.first?.progress, 8)
        session.apply(snapshot([(1, 12)]), scope: "A")
        XCTAssertEqual(session.delta(for: 1), 4)
        session.endMatch()
        XCTAssertNil(session.liveTotal(for: 1))
        XCTAssertEqual(session.snapshot?.achievements.first?.progress, 12)
    }

    func testMissingDecreasedAndStaleGameValuesAreNotDeltas() {
        var session = AccountProgressSession()
        session.switchAccount(to: "A")
        session.beginMatch("new", baseline: snapshot([(1, 8)]))
        session.updateLive([1: 10], matchID: "old")
        XCTAssertNil(session.delta(for: 1))
        session.updateLive([1: 7, 2: 5], matchID: "new")
        XCTAssertNil(session.delta(for: 1))
        XCTAssertNil(session.delta(for: 2))
        XCTAssertNil(session.liveTotal(for: 1))
        session.updateLive([1: 10], matchID: "new")
        session.invalidateLive()
        XCTAssertNil(session.delta(for: 1))
        session.updateLive([1: 11], matchID: "new")
        XCTAssertEqual(session.delta(for: 1), 3)
        session.updateLive([:], matchID: "new")
        XCTAssertNil(session.liveTotal(for: 1))
    }

    func testPinsAdvanceAcrossCompletedStagesButRequireServerRecord() {
        var session = AccountProgressSession()
        session.switchAccount(to: "A")
        let definitions = (1...3).map {
            AccountAchievementDefinition(id: $0, name: "Stage", description: "", quota: $0 * 5, nextId: $0 + 1)
        }
        session.apply(snapshot([(1, 5), (2, 10)], definitions: definitions), scope: "A")
        XCTAssertEqual(session.advancedPins([1, 99]), [2, 99])
        session.apply(snapshot([(1, 5), (2, 10), (3, 11)], definitions: definitions), scope: "A")
        XCTAssertEqual(session.advancedPins([1, 99]), [3, 99])
    }

    func testPinsHandleCyclicOrZeroQuotaDefinitions() {
        var session = AccountProgressSession()
        session.switchAccount(to: "A")
        let cycle = [AccountAchievementDefinition(id: 1, name: "", description: "", quota: 5, nextId: 2),
                     AccountAchievementDefinition(id: 2, name: "", description: "", quota: 5, nextId: 1)]
        session.apply(snapshot([(1, 5), (2, 5)], definitions: cycle), scope: "A")
        XCTAssertEqual(session.advancedPins([1]), [1])
        let zero = [AccountAchievementDefinition(id: 1, name: "", description: "", quota: 0, nextId: 2)]
        session.apply(snapshot([(1, 5), (2, 5)], definitions: zero), scope: "A")
        XCTAssertEqual(session.advancedPins([1]), [1])
    }
}
