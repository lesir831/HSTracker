import XCTest
@testable import HSTracker

@MainActor
final class AccountQuestMenuTests: XCTestCase {
    private typealias ReadResult = Result<(scope: String, reading: AccountProgressReading), Error>

    private final class Source {
        private let lock = NSLock()
        private var result: ReadResult
        private var requests: [Bool] = []

        init(_ result: ReadResult) { self.result = result }

        func read(_ full: Bool) throws -> (scope: String, reading: AccountProgressReading) {
            lock.lock(); defer { lock.unlock() }
            requests.append(full)
            return try result.get()
        }

        func set(_ result: ReadResult) {
            lock.lock(); defer { lock.unlock() }
            self.result = result
        }

        var recordedRequests: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    private func success(progress: Int = 176) -> ReadResult {
        let quest = AccountProgressRecord(id: 1035, progress: progress, status: 2)
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: [quest],
                                              achievements: [], definitions: [])
        return .success(("menu-test-account", AccountProgressReading(snapshot: snapshot, inGame: [:])))
    }

    private func makeModel(_ source: Source, overlayEnabled: Bool = true) -> AccountProgressModel {
        let definition = AccountQuestDefinition(id: 1035, description: "Spend $q mana.",
                                               quota: 500, rewardTrackType: 1)
        return AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                    overlayEnabled: overlayEnabled, definitions: [definition.id: definition],
                                    showTraditionalQuests: true, showBattlegroundsQuests: false,
                                    reader: source.read)
    }

    private func categorySuccess() -> ReadResult {
        let quests = [(1035, 176), (382, 2), (7007, 3), (9999, 4)].map {
            AccountProgressRecord(id: $0.0, progress: $0.1, status: 2)
        }
        let snapshot = AccountProgressSnapshot(capturedAt: Date(timeIntervalSince1970: 123),
                                               quests: quests, achievements: [], definitions: [])
        return .success(("menu-test-account", AccountProgressReading(snapshot: snapshot, inGame: [:])))
    }

    private func makeCategoryModel(_ source: Source) -> AccountProgressModel {
        let definitions = [
            AccountQuestDefinition(id: 1035, description: "Spend $q mana.", quota: 500,
                                   rewardTrackType: 1, schedule: .weekly),
            AccountQuestDefinition(id: 382, description: "Battlegrounds task $q", quota: 5,
                                   rewardTrackType: 2, schedule: .weekly),
            AccountQuestDefinition(id: 7007, description: "Event daily task $q", quota: 10,
                                   rewardTrackType: 7, schedule: .daily)
        ]
        return AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                    overlayEnabled: true,
                                    definitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) }),
                                    showTraditionalQuests: true, showBattlegroundsQuests: false,
                                    reader: source.read)
    }

    private func visibleExperience() -> ExperienceCounterViewModel {
        let experience = ExperienceCounterViewModel()
        experience.isShown = true
        return experience
    }

    private func idle(_ model: AccountProgressModel) async {
        let deadline = Date().addingTimeInterval(5)
        while model.refreshing && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.refreshing)
        // The projection receives published changes on the next main run-loop pass.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testColdStartHubInitializesEntryInEitherExperienceCallbackOrder() async {
        for loggedMode: Mode? in [nil, .invalid] {
            for experienceArrivesFirst in [false, true] {
                let model = makeModel(Source(success()))
                let experience = ExperienceCounterViewModel()
                let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
                let hub = Game.ExperienceScene(loggedMode: loggedMode, stableMode: .hub,
                                               isInMenu: true, gameEnded: true)
                if experienceArrivesFirst {
                    let unreadScene = Game.ExperienceScene(loggedMode: loggedMode, stableMode: nil,
                                                           isInMenu: true, gameEnded: true)
                    unreadScene.finishExperienceUpdate(experience)
                }
                hub.bootstrapMenu(model: model, counter: experience, enabled: true)
                XCTAssertFalse(hub.finishExperienceUpdate(experience))
                await idle(model)

                XCTAssertTrue(model.menuActive)
                XCTAssertTrue(experience.visible)
                XCTAssertTrue(experience.isShown)
                XCTAssertTrue(overlay.menuAvailable)
                XCTAssertFalse(overlay.menuExpanded)
            }
        }
    }

    func testColdStartUnsupportedSceneDoesNotOfferMenu() async {
        for mode in [Mode.invalid, .startup, .gameplay, .bacon, .collectionmanager] {
            let model = makeModel(Source(success()))
            let experience = visibleExperience()
            experience.show()
            model.setMenuActive(true)
            let scene = Game.ExperienceScene(loggedMode: .invalid, stableMode: mode,
                                             isInMenu: true, gameEnded: true)
            scene.bootstrapMenu(model: model, counter: experience, enabled: true)
            XCTAssertFalse(model.menuActive)
            XCTAssertFalse(experience.visible)
            XCTAssertFalse(experience.isShown)
        }
    }

    func testKnownLogModeOverridesStaleMirrorHubWithoutChangingExistingExperienceRule() {
        for mode in [Mode.gameplay, .bacon, .collectionmanager, .tournament, .hub] {
            let model = makeModel(Source(success()))
            let experience = ExperienceCounterViewModel()
            let scene = Game.ExperienceScene(loggedMode: mode, stableMode: .hub,
                                             isInMenu: true, gameEnded: true)
            XCTAssertEqual(scene.mode, mode)
            scene.bootstrapMenu(model: model, counter: experience, enabled: true)
            XCTAssertFalse(model.menuActive)
            XCTAssertFalse(experience.visible)

            experience.show()
            XCTAssertEqual(scene.finishExperienceUpdate(experience), mode != .hub)
            XCTAssertEqual(experience.visible, mode == .hub)
        }
    }

    func testDelayedMirrorHubCannotOpenMenuOrTerminateLogOwnedMatch() async {
        for (spectator, questEligible, overlayEligible) in [(false, true, true), (false, false, true), (true, false, false)] {
            let model = makeModel(Source(success()))
            let experience = ExperienceCounterViewModel()
            model.beginMatch("active-log-match", spectator: spectator, questEligible: questEligible,
                             overlayEligible: overlayEligible)
            await idle(model)
            let matchID = model.questEstimate.matchID
            let overlayActive = model.overlayMatchActive
            model.sceneChanged(Mode.hub.rawValue)

            for (isInMenu, gameEnded) in [(false, false), (false, true), (true, false)] {
                let scene = Game.ExperienceScene(loggedMode: .invalid, stableMode: .hub,
                                                 isInMenu: isInMenu, gameEnded: gameEnded)
                scene.bootstrapMenu(model: model, counter: experience, enabled: true)
                XCTAssertNil(scene.mode)
                XCTAssertFalse(model.menuActive)
                XCTAssertFalse(experience.visible)
            }
            await idle(model)
            XCTAssertEqual(model.questEstimate.matchID, matchID)
            XCTAssertEqual(model.overlayMatchActive, overlayActive)
        }
    }

    func testColdStartRespectsExperienceCounterSetting() async {
        let model = makeModel(Source(success()))
        let experience = ExperienceCounterViewModel()
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        let scene = Game.ExperienceScene(loggedMode: .invalid, stableMode: .hub,
                                         isInMenu: true, gameEnded: true)
        scene.bootstrapMenu(model: model, counter: experience, enabled: false)
        await idle(model)
        XCTAssertTrue(model.menuActive)
        XCTAssertTrue(experience.visible)
        XCTAssertFalse(experience.isShown)
        XCTAssertFalse(overlay.menuAvailable)
    }

    func testMenuRequiresEnabledOverlayMenuSceneAndVisibleExperienceBar() async {
        let source = Source(success())
        let model = makeModel(source, overlayEnabled: false)
        let experience = visibleExperience()
        model.setMenuActive(true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        await idle(model)
        XCTAssertFalse(overlay.menuAvailable)
        overlay.toggleMenu()
        XCTAssertFalse(overlay.menuExpanded)

        model.setOverlayEnabled(true)
        await idle(model)
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)

        experience.isShown = false
        await idle(model)
        XCTAssertFalse(overlay.menuAvailable)
        overlay.toggleMenu()
        XCTAssertFalse(overlay.menuExpanded)

        experience.isShown = true
        model.setMenuActive(false)
        await idle(model)
        XCTAssertFalse(overlay.menuAvailable)
        overlay.toggleMenu()
        XCTAssertFalse(overlay.menuExpanded)
    }

    func testClickOpensWithFullRefreshAndSecondClickClosesWithoutDiagnosticPanel() async {
        let source = Source(success())
        let model = makeModel(source)
        let experience = visibleExperience()
        model.setMenuActive(true)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        XCTAssertEqual(overlay.rows.first?.confirmed, 176)
        XCTAssertFalse(overlay.menuExpanded)
        let previousCount = source.recordedRequests.count
        source.set(success(progress: 191))

        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertEqual(Array(source.recordedRequests.dropFirst(previousCount)), [true])
        XCTAssertEqual(overlay.rows.first?.confirmed, 191)
        XCTAssertNil(overlay.rows.first?.estimatedDelta)
        XCTAssertFalse(model.panelVisible)
        XCTAssertFalse(overlay.isShown)

        let countAfterOpen = source.recordedRequests.count
        overlay.toggleMenu()
        await idle(model)
        XCTAssertFalse(overlay.menuExpanded)
        XCTAssertEqual(source.recordedRequests.count, countAfterOpen)
    }

    func testOpenMenuUpdatesQuestCategoriesWithoutReadingOrChangingSnapshot() async throws {
        let savedTraditional = Settings.accountQuestShowTraditional
        let savedBattlegrounds = Settings.accountQuestShowBattlegrounds
        let source = Source(categorySuccess())
        let model = makeCategoryModel(source)
        let experience = visibleExperience()
        model.setMenuActive(true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertTrue(model.showTraditionalQuests)
        XCTAssertFalse(model.showBattlegroundsQuests)
        XCTAssertEqual(overlay.rows.map(\.id), [1035, 7007, 9999])
        let original = try XCTUnwrap(model.session.snapshot)
        let requestCount = source.recordedRequests.count

        let cases: [(traditional: Bool, battlegrounds: Bool, ids: [Int])] = [
            (true, true, [1035, 382, 7007, 9999]),
            (false, true, [382]),
            (true, false, [1035, 7007, 9999])
        ]
        for option in cases {
            model.setQuestCategories(showTraditional: option.traditional, showBattlegrounds: option.battlegrounds)
            await idle(model)
            XCTAssertEqual(model.showTraditionalQuests, option.traditional)
            XCTAssertEqual(model.showBattlegroundsQuests, option.battlegrounds)
            XCTAssertEqual(overlay.rows.map(\.id), option.ids)
            XCTAssertTrue(overlay.menuAvailable)
            XCTAssertTrue(overlay.menuExpanded)
            XCTAssertEqual(source.recordedRequests.count, requestCount)
            XCTAssertEqual(model.session.snapshot?.quests, original.quests)
            XCTAssertEqual(model.session.snapshot?.capturedAt, original.capturedAt)
            XCTAssertEqual(Settings.accountQuestShowTraditional, savedTraditional)
            XCTAssertEqual(Settings.accountQuestShowBattlegrounds, savedBattlegrounds)
        }

        model.setQuestCategories(showTraditional: false, showBattlegrounds: false)
        await idle(model)
        XCTAssertTrue(overlay.rows.isEmpty)
        XCTAssertFalse(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
        XCTAssertTrue(experience.isShown)
        XCTAssertEqual(Settings.accountQuestShowTraditional, savedTraditional)
        XCTAssertEqual(Settings.accountQuestShowBattlegrounds, savedBattlegrounds)

        model.setQuestCategories(showTraditional: false, showBattlegrounds: true)
        await idle(model)
        XCTAssertEqual(overlay.rows.map(\.id), [382])
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
        XCTAssertTrue(experience.isShown)
        XCTAssertEqual(source.recordedRequests.count, requestCount)
        XCTAssertEqual(model.session.snapshot?.quests, original.quests)
        XCTAssertEqual(model.session.snapshot?.capturedAt, original.capturedAt)
        XCTAssertEqual(Settings.accountQuestShowTraditional, savedTraditional)
        XCTAssertEqual(Settings.accountQuestShowBattlegrounds, savedBattlegrounds)
    }

    func testMatchCategoryChangesKeepHiddenEstimatesAndNeverRefreshAccountData() async throws {
        let source = Source(categorySuccess())
        let model = makeCategoryModel(source)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: true)
        model.beginMatch("category-match", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.manaSpent, total: 7, matchID: "category-match", isLocalPlayer: true)
        await idle(model)
        let original = try XCTUnwrap(model.session.snapshot)
        let requestCount = source.recordedRequests.count
        XCTAssertEqual(overlay.rows.first?.estimatedDelta, 7)
        XCTAssertEqual(overlay.rows.first?.total, 183)

        model.setQuestCategories(showTraditional: false, showBattlegrounds: true)
        await idle(model)
        XCTAssertEqual(overlay.rows.map(\.id), [382])
        XCTAssertTrue(overlay.isShown)
        XCTAssertTrue(overlay.isExpanded)

        model.setQuestCategories(showTraditional: false, showBattlegrounds: false)
        await idle(model)
        XCTAssertTrue(overlay.rows.isEmpty)
        XCTAssertFalse(overlay.isShown)
        XCTAssertFalse(overlay.isExpanded)
        model.observeQuest(.manaSpent, total: 13, matchID: "category-match", isLocalPlayer: true)
        await idle(model)

        model.setQuestCategories(showTraditional: true, showBattlegrounds: false)
        await idle(model)
        XCTAssertEqual(overlay.rows.map(\.id), [1035, 7007, 9999])
        XCTAssertTrue(overlay.isShown)
        XCTAssertTrue(overlay.isExpanded)
        XCTAssertEqual(overlay.rows.first?.confirmed, 176)
        XCTAssertEqual(overlay.rows.first?.estimatedDelta, 13)
        XCTAssertEqual(overlay.rows.first?.total, 189)
        XCTAssertEqual(model.questEstimate.matchID, "category-match")
        XCTAssertTrue(model.questEstimate.hasBaseline)
        XCTAssertEqual(source.recordedRequests.count, requestCount)
        XCTAssertEqual(model.session.snapshot?.quests, original.quests)
        XCTAssertEqual(model.session.snapshot?.capturedAt, original.capturedAt)
    }

    func testPinnedMatchOverlayDoesNotAutomaticallyExpandMenu() async {
        let source = Source(success())
        let model = makeModel(source)
        let experience = visibleExperience()
        model.setMenuActive(true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: true, experience: experience)
        model.refresh(full: true)
        await idle(model)
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertTrue(overlay.isPinned)
        XCTAssertFalse(overlay.menuExpanded)

        source.set(success(progress: 191))
        model.refresh(full: true)
        await idle(model)
        XCTAssertFalse(overlay.menuExpanded)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        overlay.toggleMenu()
        XCTAssertFalse(overlay.menuExpanded)
    }

    func testHidingExperienceOrLeavingMenuClosesListWithoutReopeningIt() async {
        let source = Source(success())
        let model = makeModel(source)
        let experience = visibleExperience()
        model.setMenuActive(true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)

        experience.isShown = false
        await idle(model)
        XCTAssertFalse(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
        experience.isShown = true
        await idle(model)
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)

        overlay.toggleMenu()
        await idle(model)
        model.setMenuActive(false)
        await idle(model)
        XCTAssertFalse(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
        model.setMenuActive(true)
        await idle(model)
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)

        overlay.toggleMenu()
        await idle(model)
        model.setOverlayEnabled(false)
        await idle(model)
        XCTAssertFalse(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
    }

    func testBeginningMatchAndClosingGameDismissMenu() async {
        let source = Source(success())
        let model = makeModel(source)
        let experience = visibleExperience()
        model.setMenuActive(true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)

        model.beginMatch("menu-to-match", spectator: false, questEligible: true)
        await idle(model)
        XCTAssertFalse(model.menuActive)
        XCTAssertFalse(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
        XCTAssertTrue(overlay.isShown)

        model.endMatch()
        model.setMenuActive(true)
        await idle(model)
        XCTAssertFalse(overlay.menuExpanded)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        model.gameClosed()
        await idle(model)
        XCTAssertFalse(model.menuActive)
        XCTAssertFalse(overlay.menuAvailable)
        XCTAssertFalse(overlay.menuExpanded)
        XCTAssertTrue(overlay.rows.isEmpty)
    }

    func testFirstScopedFailureAndUnknownIdentityKeepMenuOpenWithoutExposingOldRows() async {
        let source = Source(.failure(AccountProgressReadFailure(scope: "menu-test-account",
                                                               reason: "questStateNotReady")))
        let model = makeModel(source)
        let experience = visibleExperience()
        model.setMenuActive(true)
        let overlay = AccountQuestOverlayViewModel(model: model, pinned: false, experience: experience)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertFalse(model.hasVerifiedAccount)
        XCTAssertTrue(overlay.rows.isEmpty)

        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertEqual(overlay.rows.first?.confirmed, 176)

        source.set(.failure(AccountProgressReadFailure(scope: nil, reason: "accountUnavailable")))
        model.refresh(full: true)
        await idle(model)
        XCTAssertTrue(overlay.menuAvailable)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertFalse(model.hasVerifiedAccount)
        XCTAssertTrue(overlay.rows.isEmpty)

        source.set(success(progress: 191))
        model.refresh(full: true)
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertEqual(overlay.rows.first?.confirmed, 191)
    }
}
