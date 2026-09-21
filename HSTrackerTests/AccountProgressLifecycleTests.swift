import Combine
import XCTest
import SwiftUI
@testable import HSTracker

@MainActor
final class AccountProgressLifecycleTests: XCTestCase {
    private final class Source {
        let lock = NSLock()
        var result: Result<(scope: String, reading: AccountProgressReading), Error>
        init(_ result: Result<(scope: String, reading: AccountProgressReading), Error>) { self.result = result }
        func read(_ full: Bool) throws -> (scope: String, reading: AccountProgressReading) {
            lock.lock(); defer { lock.unlock() }
            return try result.get()
        }
        func set(_ value: Result<(scope: String, reading: AccountProgressReading), Error>) {
            lock.lock(); defer { lock.unlock() }
            result = value
        }
    }

    private let quest = AccountProgressRecord(id: 1035, progress: 176, status: 2)

    func testEventSettlementChainReplacementAndMetadataRecovery() async throws {
        let catalog = Dictionary(uniqueKeysWithValues: try HistoricalEventQuestFixtures.load().map { ($0.id, $0) })
        func native(_ id: Int, chain: Bool?, pool: Int = 20) throws -> AccountNativeQuestDefinition {
            let item = try XCTUnwrap(catalog[id])
            return AccountNativeQuestDefinition(id: id, name: item.name, description: item.description,
                quota: item.quota, rewardTrackType: 7, questPoolID: pool, poolType: 3, isChainQuest: chain)
        }
        let first = AccountProgressRecord(id: 1890, progress: 100, status: 2)
        let daily = AccountProgressRecord(id: 1904, progress: 3, status: 2)
        let source = Source(metadataReading(quests: [first, daily],
            definitions: [try native(1890, chain: true), try native(1904, chain: false)]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: catalog, showTraditionalQuests: true, showBattlegroundsQuests: false, reader: source.read)
        model.beginMatch("event-game", spectator: false, questEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(overlay.rows.map(\.id), [1890, 1904])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        model.observeQuest(.manaSpent, total: 100, matchID: "event-game", isLocalPlayer: true)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [100, 3])

        // An authoritative settlement already includes every applicable bonus.
        let settled = AccountProgressRecord(id: 1890, progress: 123, status: 2)
        source.set(metadataReading(quests: [settled, daily], definitions: [try native(1890, chain: nil)]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [123, 3])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        XCTAssertNil(model.session.snapshot?.nativeQuestDefinitions.first?.isChainQuest)
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })

        // Explicit false and a changed pool replace retained chain membership.
        source.set(metadataReading(quests: [settled], definitions: [try native(1890, chain: false)]))
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[1890]?.isChainQuest, false)
        source.set(metadataReading(quests: [settled], definitions: [try native(1890, chain: true)]))
        model.refresh(full: true)
        await idle(model)
        source.set(metadataReading(quests: [settled], definitions: [try native(1890, chain: nil, pool: 21)]))
        model.refresh(full: true)
        await idle(model)
        XCTAssertNil(model.questDefinitions[1890]?.isChainQuest)

        // The full catalog does not expose a future chain step before assignment.
        let next = AccountProgressRecord(id: 1891, progress: 4, status: 2)
        source.set(metadataReading(quests: [.init(id: 1890, progress: 500, status: 4), next,
                                          .init(id: 1904, progress: 3, status: 9)],
            definitions: [try native(1891, chain: true)]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [1891])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        // Missing native metadata for a different account cannot borrow chain labels.
        source.set(metadataReading(scope: "B", quests: [next]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEvent")
        XCTAssertEqual(overlay.rows.first?.total, 4)
    }

    func testRenderHistoricalEventObjectivesAndBonuses() async throws {
        let catalog = try HistoricalEventQuestFixtures.load()
        let definitions = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let selected = [1890, 1904, 1923]
        let native = try selected.enumerated().map { index, id -> AccountNativeQuestDefinition in
            let item = try XCTUnwrap(definitions[id])
            return AccountNativeQuestDefinition(id: id, name: item.name, description: item.description,
                quota: item.quota, rewardTrackType: 7, questPoolID: 20 + index,
                poolType: index == 1 ? 1 : 3, isChainQuest: index != 1)
        }
        let source = Source(metadataReading(quests: selected.map { .init(id: $0, progress: 3, status: 2) }, definitions: native))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: definitions, showTraditionalQuests: true, showBattlegroundsQuests: false, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(overlay.rows.count, 3)
        let height = overlay.rows.reduce(AccountQuestOverlayLayout.panelChromeHeight) { $0 + $1.displayHeight }
        let frame = CGRect(x: 0, y: 0, width: AccountQuestOverlayLayout.panelWidth, height: height)
        let view = NSHostingView(rootView: AccountQuestOverlayPanel(rows: overlay.rows,
            status: overlay.status, inMatch: true, needsScroll: false)
            .frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("events.png"))
        window.close()
    }

    func testPlayerTagsDoNotRequireCardControllerTag() {
        let entity = Entity(id: 3)
        entity[.player_id] = 2
        XCTAssertFalse(entity.isControlled(by: 2))
        XCTAssertTrue(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 2))
        XCTAssertFalse(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 1))
        XCTAssertFalse(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 0))
        // An explicit player identity takes priority over a stale controller.
        entity[.controller] = 1
        XCTAssertFalse(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 1))
    }
    private func success(_ scope: String = "A") -> Result<(scope: String, reading: AccountProgressReading), Error> {
        .success((scope, AccountProgressReading(snapshot: AccountProgressSnapshot(capturedAt: Date(),
            quests: [quest], achievements: [], definitions: []), inGame: [:])))
    }

    private func idle(_ model: AccountProgressModel) async {
        let deadline = Date().addingTimeInterval(5)
        while model.refreshing && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.refreshing)
    }

    private func metadataReading(scope: String = "A", quests: [AccountProgressRecord],
                                 definitions: [AccountNativeQuestDefinition] = [])
        -> Result<(scope: String, reading: AccountProgressReading), Error> {
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: quests, achievements: [],
                                               definitions: [], nativeQuestDefinitions: definitions)
        return .success((scope, AccountProgressReading(snapshot: snapshot, inGame: [:])))
    }

    func testDelayedMirrorSceneDoesNotTerminateLogOwnedMatch() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.manaSpent, total: 7, matchID: "game", isLocalPlayer: true)
        model.sceneChanged("friendly") // delayed mirror frame after log gameStart
        await idle(model)
        XCTAssertEqual(model.questEstimate.matchID, "game")
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.total, 183)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_LiveTracking")
    }

    func testTemporaryMissingIdentityRecoversWithoutLosingBaselineOrTags() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        source.set(.failure(AccountProgressReadFailure(scope: nil, reason: "accountUnavailable")))
        model.refresh(full: false)
        await idle(model)
        XCTAssertFalse(model.hasVerifiedAccount)
        model.observeQuest(.manaSpent, total: 7, matchID: "game", isLocalPlayer: true)
        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertTrue(model.hasVerifiedAccount)
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.total, 183)
    }

    func testFirstReadFailureDoesNotAbandonMatchAndZeroEstimateIsVisible() async {
        let source = Source(.failure(AccountProgressReadFailure(scope: nil, reason: "accountUnavailable")))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_WaitingAccount")
        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.delta, 0)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_LiveTracking")
    }

    func testConfirmedAccountSwitchAndGameCloseDiscardEstimates() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.manaSpent, total: 7, matchID: "game", isLocalPlayer: true)
        source.set(success("B"))
        model.refresh(full: true)
        await idle(model)
        XCTAssertNil(model.questEstimate.matchID)
        model.gameClosed()
        XCTAssertNil(model.session.snapshot)
        XCTAssertFalse(model.hasVerifiedAccount)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_NoActiveMatch")
    }

    func testFirstKnownIdentityFailureKeepsOverlayMatchAlive() async {
        let source = Source(.failure(AccountProgressReadFailure(scope: "A", reason: "questStateNotReady")))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        XCTAssertTrue(model.overlayMatchActive)
        XCTAssertFalse(model.hasVerifiedAccount)
        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.delta, 0)
        XCTAssertTrue(model.overlayMatchActive)
    }

    func testEnablingDuringMatchShowsAccountProgressWithoutInventingOpeningBaseline() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: false, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        XCTAssertTrue(model.overlayMatchActive)
        // Automatic polling/definition downloads are disabled for this fixture.
        model.setOverlayEnabled(true)
        await idle(model)
        XCTAssertTrue(model.overlayEnabled)
        XCTAssertTrue(model.overlayMatchActive)
        XCTAssertNil(model.questEstimate.progress(for: quest, quota: 500))
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_JoinedMidMatch")
        model.endMatch()
        XCTAssertFalse(model.overlayMatchActive)
    }

    func testBattlegroundsCanDisplayQuestsWithoutTraditionalGameEstimates() async {
        let model = makeOverlayModel()
        model.beginMatch("battlegrounds", spectator: false, questEligible: false, overlayEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertTrue(overlay.isShown)
        XCTAssertFalse(overlay.rows.isEmpty)
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_MatchNotEstimated")
        model.beginMatch("spectating-battlegrounds", spectator: true, questEligible: false, overlayEligible: true)
        await idle(model)
        overlay.update()
        XCTAssertFalse(overlay.isShown)
    }

    func testNativeQuestMetadataOverridesFallbackAndTracksSnapshotReplacement() async {
        let native = AccountNativeQuestDefinition(id: 1035, name: "Mana quest", description: "Spend $q mana.",
            quota: 500, rewardTrackType: 1, questPoolID: 2, poolType: 2)
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: [quest], achievements: [],
            definitions: [], nativeQuestDefinitions: [native])
        let source = Source(.success(("fixture", AccountProgressReading(snapshot: snapshot, inGame: [:]))))
        let fallback = AccountQuestDefinition(id: 1035, description: "Old description", quota: 999, rewardTrackType: 2)
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: [1035: fallback], showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[1035]?.quota, 500)
        XCTAssertEqual(model.questDefinitions[1035]?.schedule, .weekly)
        XCTAssertEqual(model.questDefinitions[1035]?.rewardTrackType, 1)
        XCTAssertEqual(model.questDefinitions[1035]?.text, "Spend 500 mana.")
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(overlay.rows.map(\.id), [1035])

        // A reroll/claim replaces the server list; stale rows and their native
        // metadata must not survive a later authoritative snapshot.
        let replacement = AccountProgressSnapshot(capturedAt: Date(),
            quests: [AccountProgressRecord(id: 2000, progress: 4, status: 2)], achievements: [], definitions: [],
            nativeQuestDefinitions: [AccountNativeQuestDefinition(id: 2000, name: "", description: "Draw $q cards.",
                quota: 30, rewardTrackType: 2, questPoolID: 8, poolType: 1)])
        source.set(.success(("fixture", AccountProgressReading(snapshot: replacement, inGame: [:]))))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [2000])
        XCTAssertEqual(model.questDefinitions[2000]?.schedule, .daily)
        XCTAssertEqual(model.questDefinitions[1035], fallback)
    }

    func testNativeMetadataSurvivesMissingAndPartialReadsOnlyWhileTasksRemainAssigned() async {
        let quests = [AccountProgressRecord(id: 3001, progress: 2, status: 2),
                      AccountProgressRecord(id: 3002, progress: 3, status: 2)]
        let native = [AccountNativeQuestDefinition(id: 3001, name: "", description: "Event task $q", quota: 10,
                                                  rewardTrackType: 7, questPoolID: 1, poolType: 1),
                      AccountNativeQuestDefinition(id: 3002, name: "", description: "Other weekly $q", quota: 20,
                                                  rewardTrackType: 9, questPoolID: 2, poolType: 2)]
        let fallback = [3001: AccountQuestDefinition(id: 3001, description: "Old event", quota: 999, rewardTrackType: 7),
                        3002: AccountQuestDefinition(id: 3002, description: "Old other", quota: 999, rewardTrackType: 9)]
        let source = Source(metadataReading(quests: quests, definitions: native))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                         definitions: fallback, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(overlay.rows.map(\.id), [3001, 3002])

        let advanced = [AccountProgressRecord(id: 3001, progress: 4, status: 2),
                        AccountProgressRecord(id: 3002, progress: 5, status: 2)]
        source.set(metadataReading(quests: advanced))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [3001, 3002])
        XCTAssertEqual(overlay.rows.map(\.schedule), [.daily, .weekly])
        XCTAssertEqual(overlay.rows.map(\.quota), [10, 20])
        XCTAssertEqual(overlay.rows.map(\.confirmed), [4, 5])
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })
        // The display cache must not rewrite the authoritative snapshot saved to disk.
        XCTAssertEqual(model.session.snapshot?.quests, advanced)
        XCTAssertEqual(model.session.snapshot?.nativeQuestDefinitions.count, 0)

        let changedNative = AccountNativeQuestDefinition(id: 3001, name: "", description: "Updated $q", quota: 25,
                                                         rewardTrackType: 7, questPoolID: 2, poolType: 2)
        source.set(metadataReading(quests: advanced, definitions: [changedNative]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.schedule), [.weekly, .weekly])
        XCTAssertEqual(overlay.rows.map(\.quota), [25, 20])
        XCTAssertEqual(overlay.rows.first?.title, "Updated 25")

        source.set(metadataReading(quests: [advanced[0]]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [3001])
        XCTAssertEqual(model.questDefinitions[3002], fallback[3002])

        // A removed task that later reappears needs new native confirmation.
        source.set(metadataReading(quests: advanced))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [3001])
        XCTAssertEqual(model.questDefinitions[3002]?.schedule, .unknown)
    }

    func testNativeMetadataRetainsMissingCadenceOnlyForUnchangedQuestPool() async {
        let quest = AccountProgressRecord(id: 3030, progress: 2, status: 2)
        func native(pool: Int, period: Int?, quota: Int) -> AccountNativeQuestDefinition {
            AccountNativeQuestDefinition(id: quest.id, name: "", description: "Updated task $q", quota: quota,
                                         rewardTrackType: 7, questPoolID: pool, poolType: period)
        }
        let source = Source(metadataReading(quests: [quest], definitions: [native(pool: 10, period: 1, quota: 10)]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, .daily)

        let cases: [(pool: Int, period: Int?, quota: Int, schedule: AccountQuestSchedule)] = [
            (10, nil, 12, .daily), // A missing join retains its previously verified cadence.
            (10, 0, 13, .unknown), // Explicit NONE must replace the old daily value.
            (10, 2, 14, .weekly),
            (10, 99, 15, .unknown), // Future enum values are explicit, not missing.
            (10, 2, 16, .weekly),
            (11, nil, 17, .unknown) // A changed pool cannot inherit the previous pool's cadence.
        ]
        for item in cases {
            source.set(metadataReading(quests: [quest],
                definitions: [native(pool: item.pool, period: item.period, quota: item.quota)]))
            model.refresh(full: true)
            await idle(model)
            overlay.update()
            XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, item.schedule)
            XCTAssertEqual(model.questDefinitions[quest.id]?.quota, item.quota)
            XCTAssertEqual(model.questDefinitions[quest.id]?.text, "Updated task \(item.quota)")
            XCTAssertEqual(overlay.rows.map(\.id), [quest.id])
            XCTAssertEqual(model.session.snapshot?.nativeQuestDefinitions.first?.poolType, item.period)
        }
    }

    func testNativeMetadataDoesNotCrossSuccessfulOrFailedAccountSwitch() async {
        let quest = AccountProgressRecord(id: 3010, progress: 2, status: 2)
        let native = AccountNativeQuestDefinition(id: quest.id, name: "", description: "Event task $q", quota: 10,
                                                  rewardTrackType: 7, questPoolID: 1, poolType: 1)
        let fallback = AccountQuestDefinition(id: quest.id, description: "Unclassified event", quota: 10, rewardTrackType: 7)
        for failsFirst in [false, true] {
            let source = Source(metadataReading(quests: [quest], definitions: [native]))
            let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                             definitions: [quest.id: fallback], showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
            model.refresh(full: true)
            await idle(model)
            XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, .daily)

            if failsFirst {
                source.set(.failure(AccountProgressReadFailure(scope: "B", reason: "questStateNotReady")))
                model.refresh(full: true)
                await idle(model)
                XCTAssertFalse(model.hasVerifiedAccount)
                XCTAssertEqual(model.questDefinitions[quest.id], fallback)
            }
            source.set(metadataReading(scope: "B", quests: [quest]))
            model.refresh(full: true)
            await idle(model)
            XCTAssertEqual(model.questDefinitions[quest.id], fallback)
            let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
            XCTAssertEqual(overlay.rows.map(\.id), [quest.id])
            XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEvent")
        }
    }

    func testClosingGameClearsNativeMetadataBeforeSameAccountReopens() async {
        let quest = AccountProgressRecord(id: 3020, progress: 2, status: 2)
        let native = AccountNativeQuestDefinition(id: quest.id, name: "", description: "Event task $q", quota: 10,
                                                  rewardTrackType: 7, questPoolID: 1, poolType: 1)
        let fallback = AccountQuestDefinition(id: quest.id, description: "Unclassified event", quota: 10, rewardTrackType: 7)
        let source = Source(metadataReading(quests: [quest], definitions: [native]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                         definitions: [quest.id: fallback], showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, .daily)

        model.gameClosed()
        XCTAssertNil(model.session.snapshot)
        XCTAssertEqual(model.questDefinitions[quest.id], fallback)
        source.set(metadataReading(quests: [quest]))
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[quest.id], fallback)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(overlay.rows.map(\.id), [quest.id])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEvent")
    }

    func testOverlayUpdatesWithoutOpeningDiagnosticWindowAndHidesAtEnd() async throws {
        let model = makeOverlayModel()
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertFalse(model.panelVisible)
        XCTAssertTrue(overlay.isShown)
        XCTAssertEqual(overlay.rows.first?.estimatedDelta, 0)
        overlay.expireReveal()
        XCTAssertFalse(overlay.isExpanded)
        model.observeQuest(.heroPowerUses, total: 1, matchID: "game", isLocalPlayer: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(overlay.rows.first?.total, 10)
        XCTAssertTrue(overlay.isExpanded)
        model.endMatch()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(overlay.isShown)
        XCTAssertFalse(overlay.isExpanded)
        model.beginMatch("spectating", spectator: true, questEligible: true)
        await idle(model)
        overlay.update()
        XCTAssertFalse(overlay.isShown)
    }

    private func makeOverlayModel() -> AccountProgressModel {
        let quests = [AccountProgressRecord(id: 1032, progress: 9, status: 2),
                      AccountProgressRecord(id: 443, progress: 0, status: 2), quest]
        let definitions = [AccountQuestDefinition(id: 1032, description: "使用$q次英雄技能。", quota: 20, rewardTrackType: 1),
                           AccountQuestDefinition(id: 443, description: "使用死亡骑士、恶魔猎手或圣骑士完成$q场对战。", quota: 3, rewardTrackType: 1),
                           AccountQuestDefinition(id: 1035, description: "消耗$q点法力值。", quota: 500, rewardTrackType: 1)]
        let native = definitions.map {
            AccountNativeQuestDefinition(id: $0.id, name: "", description: $0.description, quota: $0.quota,
                rewardTrackType: $0.rewardTrackType, questPoolID: $0.id == 443 ? 1 : 2,
                poolType: $0.id == 443 ? 1 : 2)
        }
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: quests, achievements: [], definitions: [],
                                               nativeQuestDefinitions: native)
        return AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            overlayEnabled: true,
            definitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) }),
            showTraditionalQuests: true, showBattlegroundsQuests: true, reader: { _ in ("fixture", AccountProgressReading(snapshot: snapshot, inGame: [:])) })
    }

    /// Renders the actual production view with deterministic sample data for
    /// visual review. This is not a claim of fresh-game end-to-end acceptance.
    func testRenderQuestOverlayUsingBundledHearthstoneAssets() async throws {
        for name in ["xp_scroll_item", "xp_gem", "hs_banner", "flavor_text", "xp_empty_bar", "xp_filled_bar"] {
            XCTAssertNotNil(NSImage(named: name), "Missing bundled artwork: \(name)")
        }
        let model = makeOverlayModel()
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.heroPowerUses, total: 1, matchID: "game", isLocalPlayer: true)
        model.observeQuest(.manaSpent, total: 15, matchID: "game", isLocalPlayer: true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: true)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let view = NSHostingView(rootView: AccountQuestOverlayView(viewModel: overlay,
            placement: overlay.placement, canvasWidth: frame.width, canvasSize: frame.size, isLocked: true)
            .background(Color(red: 0.13, green: 0.17, blue: 0.17)))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("expanded.png"))
        let header = AccountQuestOverlayLayout.headerFrame(canvasWidth: frame.width,
            horizontal: overlay.placement.horizontal, vertical: overlay.placement.vertical)
        let panel = AccountQuestOverlayLayout.panelFrame(header: header, rowCount: overlay.rows.count)
        let detailRect = header.union(panel).insetBy(dx: -8, dy: -8).intersection(view.bounds)
        let detail = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: detailRect))
        view.cacheDisplay(in: detailRect, to: detail)
        try XCTUnwrap(detail.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("detail.png"))
        window.close()
    }

    func testRenderMenuQuestsAboveExistingExperienceBar() async throws {
        let model = makeOverlayModel()
        model.setMenuActive(true)
        model.refresh(full: true)
        await idle(model)
        let experience = ExperienceCounterViewModel()
        experience.isShown = true
        experience.xpDisplay = "385/1325"
        experience.levelDisplay = "102"
        experience.percentage = 385.0 / 1325
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: true, experience: experience)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertFalse(overlay.isShown)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let view = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            AccountQuestExperienceEntryView(quests: overlay, experience: experience,
                                           canvasWidth: frame.width, canvasScale: 1)
            AccountQuestMenuOverlayView(viewModel: overlay, canvasWidth: frame.width, canvasSize: frame.size)
        }.background(Color(red: 0.13, green: 0.17, blue: 0.17)))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let entry = ExperienceCounterView.visualFrame(canvasWidth: frame.width)
        let panel = AccountQuestOverlayLayout.panelFrame(header: entry, rowCount: overlay.rows.count)
        XCTAssertLessThan(panel.maxY, entry.minY)
        let detailRect = entry.union(panel).insetBy(dx: -8, dy: -8).intersection(view.bounds)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: detailRect))
        view.cacheDisplay(in: detailRect, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("menu.png"))
        window.close()
    }

    func testRenderLongRecurringObjectivesWithoutTruncation() async throws {
        let descriptions = [
            "在卡牌对战各模式中召唤$q个随从。完成指定职业、指定版本卡牌和指定模式的额外条件时，以游戏确认的任务进度为准。",
            "抽$q张牌。", "消灭$q个随从。", "赢得$q场酒馆战棋对局。",
            "使用圣骑士完成$q场对战。", "使用$q张法术牌。", "进行$q个回合。"
        ]
        let native = descriptions.enumerated().map { index, description in
            AccountNativeQuestDefinition(id: 25000 + index, name: "", description: description,
                quota: index == 3 ? 3 : 30, rewardTrackType: index == 3 ? 2 : 1,
                questPoolID: index.isMultiple(of: 2) ? 1 : 2, poolType: index.isMultiple(of: 2) ? 1 : 2)
        }
        let snapshot = AccountProgressSnapshot(capturedAt: Date(),
            quests: native.map { AccountProgressRecord(id: $0.id, progress: 1, status: 2) },
            achievements: [], definitions: [], nativeQuestDefinitions: native)
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            overlayEnabled: true, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: { _ in ("fixture", AccountProgressReading(snapshot: snapshot, inGame: [:])) })
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false)
        XCTAssertEqual(overlay.rows.count, 7)
        XCTAssertGreaterThan(overlay.rows[0].displayHeight, AccountQuestOverlayLayout.rowHeight)
        let frame = CGRect(x: 0, y: 0, width: AccountQuestOverlayLayout.panelWidth, height: 650)
        let view = NSHostingView(rootView: AccountQuestOverlayPanel(rows: overlay.rows,
            status: overlay.status, inMatch: false, needsScroll: true)
            .frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("recurring-long.png"))
        window.close()
    }
}
