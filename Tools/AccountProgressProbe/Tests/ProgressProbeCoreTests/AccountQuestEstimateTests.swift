import Foundation
import XCTest
@testable import ProgressProbeCore

final class AccountQuestEstimateTests: XCTestCase {
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
