import CoreGraphics
import XCTest
@testable import HSTracker

final class AccountQuestOverlayTests: XCTestCase {
    func testCurrentEventRulesAppearOnlyForAssignedQuestsAndKeepBonusNotes() throws {
        let catalog = try CurrentEventQuestFixtures.load()
        let definitions = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let frame = snapshot([quest(1956, 10), quest(1986, 5), quest(1957, 3), quest(1987, 2)])
        var live = estimate(for: frame)
        let context = AccountQuestEstimate.Context(ranked: true, playerClass: "warlock")
        live.observe(.played(.init(type: 5, school: 6)), eventID: "cast", matchID: "match", isLocalPlayer: true, context: context)
        live.observe(.summoned(.init(type: 4, keywords: ["DEATHRATTLE"])), eventID: "summon", matchID: "match", isLocalPlayer: true, context: context)
        let rows = AccountQuestOverlayRow.rows(snapshot: frame, definitions: definitions,
            estimate: live, hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.id), [1956, 1986, 1957, 1987])
        XCTAssertEqual(rows.map(\.total), [14, 8, 3, 2])
        XCTAssertEqual(rows.map(\.confirmed), [10, 5, 3, 2])
        XCTAssertEqual(rows.map(\.estimatedDelta), [4, 3, 0, 0])
        XCTAssertEqual(rows[0].detail, "（计数加成：排名对战+1，暗影+1，术士+1）")
        XCTAssertEqual(rows[1].detail, "（计数加成：排名对战+1，亡语+1）")
        XCTAssertTrue(AccountQuestOverlayRow.rows(snapshot: frame, definitions: definitions,
            estimate: live, hasVerifiedAccount: true, showTraditional: false).isEmpty)
    }

    func testHistoricalEventCatalogDisplaysOnlyAssignedQuestsAndPreservesAllConditions() throws {
        let catalog = try HistoricalEventQuestFixtures.load()
        XCTAssertEqual(catalog.count, 1194)
        let definitions = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        XCTAssertTrue(AccountQuestOverlayRow.rows(snapshot: snapshot([]), definitions: definitions,
            estimate: AccountQuestEstimate(), hasVerifiedAccount: true).isEmpty)
        let assigned = catalog.enumerated().map { quest($0.element.id, min($0.offset % 17, $0.element.quota)) }
        let frame = snapshot(assigned)
        let rows = AccountQuestOverlayRow.rows(snapshot: frame, definitions: definitions,
            estimate: estimate(for: frame), hasVerifiedAccount: true)
        XCTAssertEqual(rows.count, 1194)
        XCTAssertEqual(rows.map(\.id), assigned.map(\.id))
        XCTAssertEqual(rows.map(\.total), assigned.map(\.progress))
        for (row, definition) in zip(rows, catalog) {
            XCTAssertEqual(row.quota, definition.quota)
            XCTAssertEqual(row.categoryKey, "AccountProgress_CategoryEvent")
            XCTAssertNil(row.estimatedDelta)
            // Splitting a bonus note must not lose class, set, mode, card
            // attributes, co-op participation or win conditions.
            let expected = definition.text.replacingOccurrences(of: "<[^>]+>|\\s|\\[x\\]", with: "", options: .regularExpression)
            let actual = (row.title + row.detail).replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            XCTAssertEqual(actual, expected, "Quest \(row.id)")
        }
    }

    func testEventBonusExamplesRemainAuthoritativeAndSeparateFromObjectives() throws {
        let definitions = Dictionary(uniqueKeysWithValues: try HistoricalEventQuestFixtures.load().map { ($0.id, $0) })
        // Draw, summon, kill, set, class, keyword, school, mode, win and co-op.
        let examples = [1904, 1890, 1881, 1250, 1923, 1924, 1935, 1929, 1921]
        let frame = snapshot(examples.map { quest($0, 3) })
        var live = estimate(for: frame)
        live.observe(.heroPowerUses, total: 50, matchID: "match", isLocalPlayer: true)
        live.observe(.manaSpent, total: 500, matchID: "match", isLocalPlayer: true)
        let rows = AccountQuestOverlayRow.rows(snapshot: frame, definitions: definitions,
            estimate: live, hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.id), examples)
        XCTAssertTrue(rows.allSatisfy { $0.total == 3 && $0.estimatedDelta == nil })
        XCTAssertTrue(rows.allSatisfy { $0.detail.hasPrefix("（计数加成：") })
        XCTAssertEqual(rows[0].title, "抽30张牌。")
        XCTAssertEqual(rows[0].detail, "（计数加成：排名对战+1）")
        XCTAssertTrue(rows[3].detail.contains("安戈洛龟途牌+2"))
        XCTAssertTrue(rows[4].detail.contains("胜场+1，战士+1"))
        XCTAssertTrue(rows[5].detail.contains("亡语+1，术士+1"))
        XCTAssertTrue(rows[6].detail.contains("暗影+1，火焰+1"))
        XCTAssertTrue(rows[8].title.hasPrefix("合作："))
        XCTAssertGreaterThan(rows[3].displayHeight, AccountQuestOverlayLayout.rowHeight)
    }

    func testEventChainClassificationRequiresNativeEvidenceAndNeverGuessesDaily() {
        let cases: [(AccountQuestSchedule, Bool?, String)] = [
            (.event, true, "AccountProgress_CategoryEventChain"),
            (.event, false, "AccountProgress_CategoryEvent"),
            (.event, nil, "AccountProgress_CategoryEvent"),
            (.daily, false, "AccountProgress_CategoryEventDaily"),
            (.weekly, false, "AccountProgress_CategoryEventWeekly"),
            (.unknown, nil, "AccountProgress_CategoryEvent")
        ]
        for item in cases {
            let definition = AccountQuestDefinition(id: 1890, description: "Summon $q", quota: 500,
                rewardTrackType: 7, schedule: item.0, isChainQuest: item.1)
            let rows = AccountQuestOverlayRow.rows(snapshot: snapshot([quest(1890, 0)]),
                definitions: [1890: definition], estimate: AccountQuestEstimate(), hasVerifiedAccount: true)
            XCTAssertEqual(rows.first?.categoryKey, item.2)
        }
    }

    func testEventDefinitionCannotReuseOrdinaryQuestEstimateOrResurrectExpiredTasks() {
        let frame = snapshot([quest(1032, 2), .init(id: 1890, progress: 15, status: 9),
                              .init(id: 1881, progress: 75, status: 4)])
        let definitions = [1032: definition(1032, quota: 20, track: 7, schedule: .event),
                           1890: definition(1890, quota: 500, track: 7, schedule: .event),
                           1881: definition(1881, quota: 75, track: 7, schedule: .event)]
        var live = estimate(for: frame)
        live.observe(.heroPowerUses, total: 10, matchID: "match", isLocalPlayer: true)
        let rows = AccountQuestOverlayRow.rows(snapshot: frame, definitions: definitions,
            estimate: live, hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.id), [1032])
        XCTAssertEqual(rows.first?.total, 2)
        XCTAssertNil(rows.first?.estimatedDelta)
    }

    func testEventNotesDoNotDependOnLanguageAndUnknownMarkupKeepsItsText() {
        let texts = ["Draw $q cards.<i>(Bonus: Ranked +1)</i>",
                     "Draw $q cards. Bonus: Ranked +1", "<i>Only a note</i>",
                     "Draw $q cards.<i>(Bonus: <b>Ranked</b> +1)</i>"]
        let definitions = Dictionary(uniqueKeysWithValues: texts.enumerated().map {
            ($0.offset, definition($0.offset, quota: 30, track: 7, description: $0.element))
        })
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot(texts.indices.map { quest($0, 0) }),
            definitions: definitions, estimate: AccountQuestEstimate(), hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.detail), ["(Bonus: Ranked +1)", "", "", "(Bonus: Ranked +1)"])
        XCTAssertEqual(rows.map(\.title), ["Draw 30 cards.", "Draw 30 cards. Bonus: Ranked +1", "Only a note", "Draw 30 cards."])
    }

    func testMaskedGameDialogsKeepHiddenButtonsClickThrough() {
        let mask = OverlayOpacityMask()
        let size = CGSize(width: 1920, height: 1080)
        mask.addMaskedRegion("game-menu", CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6))
        XCTAssertTrue(mask.hides(CGPoint(x: 960, y: 540), canvasSize: size))
        XCTAssertFalse(mask.hides(CGPoint(x: 100, y: 100), canvasSize: size))
        mask.disable()
        XCTAssertFalse(mask.hides(CGPoint(x: 960, y: 540), canvasSize: size))
        mask.enable()
        XCTAssertTrue(mask.hides(CGPoint(x: 960, y: 540), canvasSize: size))
        mask.removeMaskedRegion("game-menu")
        XCTAssertFalse(mask.hides(CGPoint(x: 960, y: 540), canvasSize: size))
    }

    private func snapshot(_ quests: [AccountProgressRecord]) -> AccountProgressSnapshot {
        AccountProgressSnapshot(capturedAt: Date(timeIntervalSince1970: 0),
                                quests: quests, achievements: [], definitions: [])
    }

    private func quest(_ id: Int, _ progress: Int) -> AccountProgressRecord {
        AccountProgressRecord(id: id, progress: progress, status: 2)
    }

    private func definition(_ id: Int, quota: Int, track: Int = 1,
                            description: String = "Task $q", name: String = "",
                            schedule: AccountQuestSchedule = .unknown) -> AccountQuestDefinition {
        AccountQuestDefinition(id: id, description: description, quota: quota, rewardTrackType: track,
                               name: name, schedule: schedule)
    }

    private func estimate(for snapshot: AccountProgressSnapshot) -> AccountQuestEstimate {
        var estimate = AccountQuestEstimate()
        estimate.beginMatch("match", eligible: true)
        estimate.bind(snapshot, scope: "test-account")
        return estimate
    }

    func testUnverifiedAccountAndMissingSnapshotProduceNoRows() {
        let snapshot = snapshot([quest(1032, 9)])
        let definitions = [1032: definition(1032, quota: 20)]
        XCTAssertTrue(AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                                 estimate: estimate(for: snapshot),
                                                 hasVerifiedAccount: false).isEmpty)
        XCTAssertTrue(AccountQuestOverlayRow.rows(snapshot: nil, definitions: definitions,
                                                 estimate: estimate(for: snapshot),
                                                 hasVerifiedAccount: true).isEmpty)
    }

    func testUnknownOrdinaryAndBattlegroundSchedulesRemainVisibleInSnapshotOrder() {
        let snapshot = snapshot([quest(9999, 4), quest(382, 2), quest(1032, 9), quest(1035, 176)])
        let definitions = [382: definition(382, quota: 5, track: 2),
                           1032: definition(1032, quota: 20, description: " [x]<b>使用$q次</b>英雄技能。 ")]
        var estimate = estimate(for: snapshot)
        estimate.observe(.manaSpent, total: 7, matchID: "match", isLocalPlayer: true)
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                               estimate: estimate, hasVerifiedAccount: true,
                                               showTraditional: true, showBattlegrounds: true)
        XCTAssertEqual(rows.map(\.id), [9999, 382, 1032, 1035])
        XCTAssertEqual(rows[0].title, "#9999")
        XCTAssertEqual(rows[0].quota, 0)
        XCTAssertEqual(rows[0].total, 4)
        XCTAssertNil(rows[0].estimatedDelta)
        XCTAssertNil(rows[0].rewardTrackType)
        XCTAssertEqual(rows[0].schedule, .unknown)
        XCTAssertEqual(rows[1].rewardTrackType, 2)
        XCTAssertEqual(rows[1].schedule, .unknown)
        XCTAssertEqual(rows[2].title, "使用20次英雄技能。")
        // Even a supported quest ID needs a known quota before it may be estimated.
        XCTAssertEqual(rows[3].title, "#1035")
        XCTAssertEqual(rows[3].quota, 0)
        XCTAssertEqual(rows[3].total, 176)
        XCTAssertNil(rows[3].estimatedDelta)
    }

    func testExplicitDailyAndWeeklySchedulesIncludeAllTracksWithoutGuessingUnknownCadence() {
        let cases: [(id: Int, track: Int, schedule: AccountQuestSchedule)] = [
            (20001, 1, .daily), (20002, 1, .weekly),
            (20003, 2, .daily), (20004, 2, .weekly),
            (20005, 7, .daily), (20006, 7, .weekly),
            (20007, 1, .unknown), (20008, 2, .unknown),
            (20009, 7, .event), (20010, 7, .unknown),
            (20011, 8, .daily), (20012, 9, .weekly),
            (20013, 0, .daily), (20014, 99, .weekly),
            (20015, 1, .event), (20016, 2, .event),
            (20017, 8, .unknown), (20018, 9, .unknown),
            (20019, 0, .unknown), (20020, 99, .unknown)
        ]
        let snapshot = snapshot(cases.map { quest($0.id, 2) })
        var definitions = Dictionary(uniqueKeysWithValues: cases.map {
            ($0.id, definition($0.id, quota: 10, track: $0.track, schedule: $0.schedule))
        })
        // Definitions list available tasks; only the account snapshot assigns one.
        definitions[20999] = definition(20999, quota: 10, schedule: .daily)
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                              estimate: estimate(for: snapshot), hasVerifiedAccount: true,
                                              showTraditional: true, showBattlegrounds: true)
        XCTAssertEqual(rows.map(\.id), Array(20001...20016))
        XCTAssertEqual(rows.map(\.schedule), [.daily, .weekly, .daily, .weekly, .daily, .weekly,
                                             .unknown, .unknown, .event, .unknown, .daily, .weekly, .daily, .weekly, .event, .event])
        XCTAssertEqual(rows.compactMap(\.rewardTrackType), [1, 1, 2, 2, 7, 7, 1, 2, 7, 7, 8, 9, 0, 99, 1, 2])
        XCTAssertEqual(rows.map(\.categoryKey), [
            "AccountProgress_CategoryDaily", "AccountProgress_CategoryWeekly",
            "AccountProgress_CategoryBattlegroundsDaily", "AccountProgress_CategoryBattlegroundsWeekly",
            "AccountProgress_CategoryEventDaily", "AccountProgress_CategoryEventWeekly",
            "AccountProgress_CategoryUnknown", "AccountProgress_CategoryBattlegroundsUnknown",
            "AccountProgress_CategoryEvent", "AccountProgress_CategoryEvent",
            "AccountProgress_CategoryDaily", "AccountProgress_CategoryWeekly",
            "AccountProgress_CategoryDaily", "AccountProgress_CategoryWeekly",
            "AccountProgress_CategoryEvent", "AccountProgress_CategoryBattlegroundsEvent"
        ])
        XCTAssertTrue(rows.allSatisfy { $0.estimatedDelta == nil })
    }

    func testQuestCategoryPreferencesDefaultToTraditionalAndFilterIndependently() {
        let quests = [quest(1035, 176), quest(24001, 2), quest(24002, 3), quest(24003, 4),
                      quest(24004, 5), quest(24005, 6), quest(24006, 7), quest(24007, 8)]
        let snapshot = snapshot(quests)
        let definitions = [
            1035: definition(1035, quota: 500, schedule: .daily),
            24001: definition(24001, quota: 10, track: 2, schedule: .daily),
            24002: definition(24002, quota: 10, track: 2, schedule: .weekly),
            24003: definition(24003, quota: 10, track: 7, schedule: .daily),
            24004: definition(24004, quota: 10, track: 99, schedule: .weekly),
            // 24005 has no metadata and follows the traditional preference.
            24006: definition(24006, quota: 10, track: 2),
            24007: definition(24007, quota: 10, track: 7, schedule: .event)
        ]
        var estimate = estimate(for: snapshot)
        estimate.observe(.manaSpent, total: 7, matchID: "match", isLocalPlayer: true)
        let traditionalIDs = [1035, 24003, 24004, 24005, 24007]
        let battlegroundIDs = [24001, 24002, 24006]
        let defaults = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                                   estimate: estimate, hasVerifiedAccount: true)
        XCTAssertEqual(defaults.map(\.id), traditionalIDs)
        XCTAssertEqual(defaults.first?.confirmed, 176)
        XCTAssertEqual(defaults.first?.estimatedDelta, 7)
        XCTAssertEqual(defaults.first?.total, 183)

        let cases: [(traditional: Bool, battlegrounds: Bool, ids: [Int])] = [
            (true, false, traditionalIDs),
            (false, true, battlegroundIDs),
            (true, true, quests.map(\.id)),
            (false, false, [])
        ]
        for option in cases {
            let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                                  estimate: estimate, hasVerifiedAccount: true,
                                                  showTraditional: option.traditional,
                                                  showBattlegrounds: option.battlegrounds)
            XCTAssertEqual(rows.map(\.id), option.ids)
            XCTAssertEqual(rows.map(\.confirmed), quests.filter { option.ids.contains($0.id) }.map(\.progress))
        }
        XCTAssertEqual(snapshot.quests, quests)
        let restored = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                                   estimate: estimate, hasVerifiedAccount: true)
        XCTAssertEqual(restored, defaults)
    }

    func testAllObjectiveTypesRemainVisibleWithoutIntroducingNewEstimates() {
        let descriptions = ["抽取$q张牌。", "召唤$q个随从。", "消灭$q个随从。",
                            "使用圣骑士完成$q场对战。", "赢得$q场对战。"]
        let quests = descriptions.indices.map { quest(21000 + $0, $0 + 1) }
        let snapshot = snapshot(quests)
        let definitions = Dictionary(uniqueKeysWithValues: descriptions.enumerated().map {
            (21000 + $0.offset, definition(21000 + $0.offset, quota: 20,
                                           description: $0.element, schedule: .daily))
        })
        var estimate = estimate(for: snapshot)
        estimate.observe(.heroPowerUses, total: 7, matchID: "match", isLocalPlayer: true)
        estimate.observe(.manaSpent, total: 100, matchID: "match", isLocalPlayer: true)
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                              estimate: estimate, hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.id), quests.map(\.id))
        XCTAssertEqual(rows.map(\.total), quests.map(\.progress))
        XCTAssertEqual(rows.map(\.confirmed), quests.map(\.progress))
        XCTAssertTrue(rows.allSatisfy { $0.estimatedDelta == nil })
    }

    func testLongDescriptionsArePreservedAndMissingDescriptionUsesNameBeforeID() {
        let longCondition = String(repeating: "在指定模式中使用指定职业，满足这项额外条件后，", count: 30)
        let snapshot = snapshot([quest(22001, 2), quest(22002, 2), quest(22003, 2)])
        let definitions = [
            22001: definition(22001, quota: 10, description: " [x]<b>\(longCondition)</b>完成$q次。 ", schedule: .weekly),
            22002: definition(22002, quota: 0, description: " <b></b> ", name: " [x]任务名称 ", schedule: .daily),
            22003: definition(22003, quota: -1, description: " ", schedule: .daily)
        ]
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                              estimate: estimate(for: snapshot), hasVerifiedAccount: true)
        XCTAssertEqual(rows[0].title, longCondition + "完成10次。")
        XCTAssertGreaterThan(rows[0].displayHeight, AccountQuestOverlayLayout.rowHeight)
        XCTAssertEqual(rows[1].title, "任务名称")
        XCTAssertEqual(rows[2].title, "#22003")
        for row in rows.dropFirst() {
            XCTAssertEqual(row.quota, 0)
            XCTAssertEqual(row.total, 2)
            XCTAssertEqual(row.fraction, 0)
            XCTAssertEqual(row.displayHeight, AccountQuestOverlayLayout.rowHeight)
            XCTAssertFalse(row.isConfirmedComplete)
            XCTAssertFalse(row.isEstimatedComplete)
        }
    }

    func testDescriptionMarkupPreservesLineAndParagraphBreaks() {
        let snapshot = snapshot([quest(22501, 0), quest(22502, 0), quest(22503, 0)])
        let definitions = [
            22501: definition(22501, quota: 10, description: "第一条件<br>第二条件<BR />第三条件", schedule: .daily),
            22502: definition(22502, quota: 10, description: "<p>第一段</p><p class=\"condition\"><b>第二段</b></p>", schedule: .daily),
            22503: definition(22503, quota: 10, description: "第一行\\n第二行<div>第三行</div>第四行", schedule: .daily)
        ]
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                              estimate: AccountQuestEstimate(), hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.title), ["第一条件\n第二条件\n第三条件", "第一段\n\n第二段", "第一行\n第二行\n第三行\n第四行"])
    }

    func testQuestLifecycleFiltersOnlyKnownRemovedStatesAndRetainsRawUnknownStatuses() {
        let statuses = [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, Int.max]
        let quests = statuses.enumerated().map { AccountProgressRecord(id: 23000 + $0.offset, progress: 2, status: $0.element) }
        let snapshot = snapshot(quests)
        let definitions = Dictionary(uniqueKeysWithValues: quests.map {
            ($0.id, definition($0.id, quota: 10, schedule: .daily))
        })
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                              estimate: estimate(for: snapshot), hasVerifiedAccount: true)
        XCTAssertEqual(rows.map(\.status), [-1, 0, 1, 2, 3, 10, Int.max])
        XCTAssertEqual(rows.filter(\.isConfirmedComplete).map(\.status), [3])
        XCTAssertTrue(rows.allSatisfy { $0.confirmed == 2 && $0.total == 2 })

        // The client can confirm completion before definition metadata loads.
        let completed = self.snapshot([AccountProgressRecord(id: 23999, progress: 2, status: 3)])
        let unknownDefinitionRows = AccountQuestOverlayRow.rows(snapshot: completed, definitions: [:],
                                                               estimate: AccountQuestEstimate(), hasVerifiedAccount: true)
        XCTAssertEqual(unknownDefinitionRows.first?.quota, 0)
        XCTAssertEqual(unknownDefinitionRows.first?.total, 2)
        XCTAssertEqual(unknownDefinitionRows.first?.fraction, 0)
        XCTAssertEqual(unknownDefinitionRows.first?.isConfirmedComplete, true)
        XCTAssertEqual(unknownDefinitionRows.first?.isEstimatedComplete, false)
    }

    func testVariableHeightPanelFitsLongDescriptionsWithoutGrowingPastCanvas() {
        let header = AccountQuestOverlayLayout.headerFrame(canvasWidth: 1920, horizontal: 99, vertical: 93)
        let short = AccountQuestOverlayRow(id: 1, title: "Short task", confirmed: 0, total: 0,
                                          quota: 1, estimatedDelta: nil)
        let long = AccountQuestOverlayRow(id: 2, title: String(repeating: "A longer condition with additional details. ", count: 15),
                                         confirmed: 0, total: 0, quota: 1, estimatedDelta: nil)
        XCTAssertEqual(short.displayHeight, AccountQuestOverlayLayout.rowHeight)
        XCTAssertGreaterThan(long.displayHeight, short.displayHeight)
        let contentHeight = short.displayHeight + long.displayHeight
        let panel = AccountQuestOverlayLayout.panelFrame(header: header, contentHeight: contentHeight)
        XCTAssertEqual(panel.height, min(AccountQuestOverlayLayout.maximumPanelHeight,
                                        contentHeight + AccountQuestOverlayLayout.panelChromeHeight))
        assertInsideCanvas(panel, width: 1920)
        let invalidHeights: [CGFloat] = [-1, 0, 10000, .nan, .infinity, -.infinity]
        for height in invalidHeights {
            let frame = AccountQuestOverlayLayout.panelFrame(header: header, contentHeight: height)
            assertInsideCanvas(frame, width: 1920)
            XCTAssertLessThanOrEqual(frame.height, AccountQuestOverlayLayout.maximumPanelHeight)
        }
    }

    func testVerifiedQuestDefinitionsExposeZeroAndCumulativeEstimatesWithoutChangingConfirmedProgress() {
        let snapshot = snapshot([quest(1032, 9), quest(1035, 176)])
        let definitions = [1032: definition(1032, quota: 20), 1035: definition(1035, quota: 500)]
        var estimate = estimate(for: snapshot)
        let initialRows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                                      estimate: estimate, hasVerifiedAccount: true)
        XCTAssertEqual(initialRows.map(\.estimatedDelta), [0, 0])
        XCTAssertEqual(initialRows.map(\.total), [9, 176])

        estimate.observe(.heroPowerUses, total: 1, matchID: "match", isLocalPlayer: true)
        estimate.observe(.manaSpent, total: 7, matchID: "match", isLocalPlayer: true)
        // Duplicate cumulative tags must not be added twice by the projection.
        estimate.observe(.manaSpent, total: 7, matchID: "match", isLocalPlayer: true)
        let updatedRows = AccountQuestOverlayRow.rows(snapshot: snapshot, definitions: definitions,
                                                      estimate: estimate, hasVerifiedAccount: true)
        XCTAssertEqual(updatedRows.map(\.estimatedDelta), [1, 7])
        XCTAssertEqual(updatedRows.map(\.total), [10, 183])
        XCTAssertEqual(updatedRows.map(\.confirmed), [9, 176])
        XCTAssertEqual(snapshot.quests.map(\.progress), [9, 176])
        XCTAssertEqual(updatedRows[0].fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(updatedRows[1].fraction, 183.0 / 500, accuracy: 0.0001)
    }

    func testUnsupportedDefinitionQuotaNeverGetsAnEstimate() {
        let snapshot = snapshot([quest(1032, 9)])
        var estimate = estimate(for: snapshot)
        estimate.observe(.heroPowerUses, total: 1, matchID: "match", isLocalPlayer: true)
        let rows = AccountQuestOverlayRow.rows(snapshot: snapshot,
                                               definitions: [1032: definition(1032, quota: 21)],
                                               estimate: estimate, hasVerifiedAccount: true)
        XCTAssertEqual(rows.first?.total, 9)
        XCTAssertNil(rows.first?.estimatedDelta)
    }

    func testEstimatedCompletionStaysDistinctFromConfirmedCompletion() throws {
        let baseline = snapshot([quest(1032, 19)])
        let definitions = [1032: definition(1032, quota: 20)]
        var estimate = estimate(for: baseline)
        estimate.observe(.heroPowerUses, total: 2, matchID: "match", isLocalPlayer: true)
        let estimated = try XCTUnwrap(AccountQuestOverlayRow.rows(snapshot: baseline,
                                                                  definitions: definitions,
                                                                  estimate: estimate,
                                                                  hasVerifiedAccount: true).first)
        XCTAssertEqual(estimated.total, 20)
        XCTAssertEqual(estimated.confirmed, 19)
        XCTAssertEqual(estimated.estimatedDelta, 2)
        XCTAssertEqual(estimated.fraction, 1)
        XCTAssertTrue(estimated.isEstimatedComplete)
        XCTAssertFalse(estimated.isConfirmedComplete)

        estimate.endMatch()
        let confirmed = try XCTUnwrap(AccountQuestOverlayRow.rows(snapshot: snapshot([quest(1032, 20)]),
                                                                  definitions: definitions,
                                                                  estimate: estimate,
                                                                  hasVerifiedAccount: true).first)
        XCTAssertTrue(confirmed.isConfirmedComplete)
        XCTAssertFalse(confirmed.isEstimatedComplete)
        XCTAssertNil(confirmed.estimatedDelta)
    }

    func testProgressFractionClampsAndUnknownQuotaCannotBeComplete() {
        let over = AccountQuestOverlayRow(id: 1, title: "", confirmed: 25, total: 25,
                                         quota: 20, estimatedDelta: nil)
        let negative = AccountQuestOverlayRow(id: 2, title: "", confirmed: -1, total: -1,
                                             quota: 20, estimatedDelta: nil)
        let unknown = AccountQuestOverlayRow(id: 3, title: "", confirmed: 25, total: 25,
                                            quota: 0, estimatedDelta: nil)
        XCTAssertEqual(over.fraction, 1)
        XCTAssertEqual(negative.fraction, 0)
        XCTAssertEqual(unknown.fraction, 0)
        XCTAssertFalse(unknown.isConfirmedComplete)
        XCTAssertFalse(unknown.isEstimatedComplete)
    }

    func testLayoutStaysInsideFourThreeWidescreenAndUltrawideCanvases() {
        let percentages: [Double] = [-100, 0, 1, 50, 93, 99, 100, 200, .nan, .infinity, -.infinity]
        for width in [CGFloat(1440), 1920, 2560] {
            for horizontal in percentages {
                for vertical in percentages {
                    let header = AccountQuestOverlayLayout.headerFrame(canvasWidth: width,
                                                                       horizontal: horizontal,
                                                                       vertical: vertical)
                    assertInsideCanvas(header, width: width)
                    XCTAssertEqual(header.size, AccountQuestOverlayLayout.headerSize)
                    for rowCount in [0, 1, 3, 6, 1000, Int.max] {
                        let panel = AccountQuestOverlayLayout.panelFrame(header: header, rowCount: rowCount)
                        assertInsideCanvas(panel, width: width)
                        XCTAssertFalse(header.intersects(panel))
                        XCTAssertLessThanOrEqual(panel.height, AccountQuestOverlayLayout.maximumPanelHeight)
                    }
                }
            }
        }
    }

    func testPanelOpensAboveBottomHeaderAndBelowTopHeaderWithScrollableLongLists() {
        let bottom = AccountQuestOverlayLayout.headerFrame(canvasWidth: 1920, horizontal: 99, vertical: 93)
        let above = AccountQuestOverlayLayout.panelFrame(header: bottom, rowCount: 3)
        XCTAssertEqual(above.maxY + AccountQuestOverlayLayout.panelGap, bottom.minY, accuracy: 0.001)
        let top = AccountQuestOverlayLayout.headerFrame(canvasWidth: 1920, horizontal: 99, vertical: 0)
        let below = AccountQuestOverlayLayout.panelFrame(header: top, rowCount: 3)
        XCTAssertEqual(top.maxY + AccountQuestOverlayLayout.panelGap, below.minY, accuracy: 0.001)

        let longList = AccountQuestOverlayLayout.panelFrame(header: bottom, rowCount: 1000)
        XCTAssertEqual(longList.height, AccountQuestOverlayLayout.maximumPanelHeight)
        XCTAssertLessThan(longList.height - AccountQuestOverlayLayout.panelChromeHeight,
                          1000 * AccountQuestOverlayLayout.rowHeight)
    }

    private func assertInsideCanvas(_ frame: CGRect, width: CGFloat,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite &&
                      frame.width.isFinite && frame.height.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, AccountQuestOverlayLayout.margin, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, AccountQuestOverlayLayout.margin, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, width - AccountQuestOverlayLayout.margin, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, AccountQuestOverlayLayout.canvasHeight - AccountQuestOverlayLayout.margin,
                                 file: file, line: line)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
    }
}

/// Public historical descriptions; all account progress used by tests is synthetic.
enum HistoricalEventQuestFixtures {
    static func load() throws -> [AccountQuestDefinition] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/event-quests.zhCN.json")
        return try JSONDecoder().decode(AccountQuestDefinitions.self, from: Data(contentsOf: url)).quests
    }
}

enum CurrentEventQuestFixtures {
    static func load() throws -> [AccountQuestDefinition] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/AccountProgressProbe/Tests/ProgressProbeCoreTests/Fixtures/event-quests-20261007.json")
        return try JSONDecoder().decode(AccountQuestDefinitions.self, from: Data(contentsOf: url)).quests
    }
}
