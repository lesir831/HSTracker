import SwiftUI
import XCTest
@testable import HSTracker

final class HearthArenaTests: XCTestCase {
    static func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/heartharena-tierlist.html"))
    }

    func testPublicPageExcerptMatchesStableIDsAndClassSpecificRatings() throws {
        let list = try HearthArenaTierList.parse(Self.fixture(), fetchedAt: .distantPast)
        XCTAssertEqual(Set(list.ratings.keys), HearthArenaTierList.classKeys)
        XCTAssertEqual(list.score(cardID: "CATA_156", heroClass: .deathknight), 115)
        XCTAssertEqual(list.score(cardID: "JAIL_101", heroClass: .deathknight), 103)
        XCTAssertNil(list.score(cardID: "CATA_156", heroClass: .mage))
        XCTAssertNil(list.score(cardID: "unknown", heroClass: .mage))
        XCTAssertNil(list.score(cardID: "JAIL_101", heroClass: .neutral))
        XCTAssertEqual(HearthArenaTierList.classKey(.demonhunter), "demon-hunter")
        XCTAssertEqual(list.score(cardID: "TIME_045", heroClass: .deathknight), 103)
        XCTAssertEqual(list.score(cardID: "TIME_045", heroClass: .priest), 106)
    }

    func testIncompleteChallengeAndConflictingPagesAreRejected() throws {
        let original = try XCTUnwrap(String(data: Self.fixture(), encoding: .utf8))
        for text in ["<html>Just a moment...</html>",
                     original.replacingOccurrences(of: "id=\"warrior\"", with: "id=\"removed\""),
                     original.replacingOccurrences(of: ">115</dd>", with: ">not a number</dd>"),
                     original.replacingOccurrences(of: "CATA_780.webp", with: "JAIL_101.webp")] {
            XCTAssertThrowsError(try HearthArenaTierList.parse(Data(text.utf8), fetchedAt: Date()))
        }
    }

    func testScoresKeepTheirOriginalScaleAndZeroWhileTrendArrowsAreNotScores() throws {
        var text = try XCTUnwrap(String(data: Self.fixture(), encoding: .utf8))
        text = text.replacingOccurrences(of: ">115</dd>", with: ">0↓</dd>")
        text = text.replacingOccurrences(of: ">103</dd>", with: ">103.5↑</dd>")
        let list = try HearthArenaTierList.parse(Data(text.utf8), fetchedAt: Date())
        XCTAssertEqual(list.score(cardID: "CATA_156", heroClass: .deathknight), 0)
        XCTAssertEqual(list.score(cardID: "JAIL_101", heroClass: .deathknight), 103.5)
    }

    func testDownloadedFullPageWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["HEARTHARENA_VALIDATION_HTML"] else {
            throw XCTSkip("Pass TEST_RUNNER_HEARTHARENA_VALIDATION_HTML for a downloaded public-page contract check")
        }
        let list = try HearthArenaTierList.parse(Data(contentsOf: URL(fileURLWithPath: path)), fetchedAt: Date())
        XCTAssertTrue(list.ratings.values.allSatisfy { $0.count > 100 })
        XCTAssertEqual(list.score(cardID: "CATA_156", heroClass: .deathknight), 115)
    }

    func testLivePublicRequestWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["HEARTHARENA_VALIDATION_LIVE"] == "1" else {
            throw XCTSkip("Opt in with TEST_RUNNER_HEARTHARENA_VALIDATION_LIVE=1")
        }
        let service = HearthArenaRatingsService(cacheURL: nil)
        let result = try await service.ratings()
        XCTAssertFalse(result.isStale)
        XCTAssertTrue(result.list.ratings.values.allSatisfy { $0.count > 100 })
    }

    actor FetchCounter {
        var count = 0
        let data: Data
        init(_ data: Data) { self.data = data }
        func fetch() async throws -> Data {
            count += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return data
        }
    }

    func testConcurrentPicksCoalesceAndFreshCacheAvoidsAnotherRequest() async throws {
        let counter = FetchCounter(try Self.fixture())
        let service = HearthArenaRatingsService(cacheURL: nil, fetch: { try await counter.fetch() })
        async let first = service.ratings()
        async let second = service.ratings()
        let results = try await [first, second]
        XCTAssertEqual(results[0].list, results[1].list)
        _ = try await service.ratings()
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testFailedRefreshLabelsBoundedStaleCacheAndDoesNotReplaceIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ratings.json")
        let now = Date()
        let old = try HearthArenaTierList.parse(Self.fixture(), fetchedAt: now.addingTimeInterval(-90_000))
        let data = try JSONEncoder().encode(old)
        try data.write(to: url)
        let service = HearthArenaRatingsService(cacheURL: url, now: { now }, fetch: { Data("blocked".utf8) })
        let result = try await service.ratings()
        XCTAssertTrue(result.isStale)
        XCTAssertEqual(result.list, old)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let again = try await service.ratings()
        XCTAssertTrue(again.isStale)
    }

    func testExpiredOrFutureDatedCacheCannotMasqueradeAsCurrentRatings() async throws {
        let now = Date()
        for age: TimeInterval in [8 * 24 * 60 * 60, -60] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let list = try HearthArenaTierList.parse(Self.fixture(), fetchedAt: now.addingTimeInterval(-age))
            try JSONEncoder().encode(list).write(to: url)
            let service = HearthArenaRatingsService(cacheURL: url, now: { now }, fetch: { throw URLError(.notConnectedToInternet) })
            do { _ = try await service.ratings(); XCTFail("Unusable cache returned") }
            catch { /* Expected unavailable, not a made-up score. */ }
        }
    }
}

@MainActor
final class HearthArenaPickTests: XCTestCase {
    private static let offers = ["CATA_156", "JAIL_101", "NOT_LISTED"].enumerated().map {
        ArenaDraftChoice(index: $0.offset, cardId: $0.element)
    }

    private func model(loader: HearthArenaPickViewModel.Loader? = nil) throws -> HearthArenaPickViewModel {
        let list = try HearthArenaTierList.parse(HearthArenaTests.fixture(), fetchedAt: Date())
        return HearthArenaPickViewModel(watcher: nil, enabled: true,
            loader: loader ?? { HearthArenaRatingsResult(list: list, isStale: false) }, lookup: { id in
                switch id {
                case "hero": return (.hero, .deathknight)
                case "other-power": return (.hero_power, .mage)
                case "power": return (.hero_power, .deathknight)
                case "NOT_LISTED": return nil
                default: return (.minion, .neutral)
                }
            })
    }

    private func start(_ model: HearthArenaPickViewModel) {
        model.setClientState(.init(clientState: .normalDraft, sessionState: .invalid))
        model.setHero("hero")
        model.setChoices(Self.offers)
    }

    private func settle(_ model: HearthArenaPickViewModel) async {
        for _ in 0..<100 where model.statusKey == "HearthArena_Loading" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testIndependentCardRatingsAndMissingValuesFollowOfferSlotOrder() async throws {
        let model = try model()
        start(model)
        model.setChoices(Array(Self.offers.reversed()))
        await settle(model)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.rows.map(\.cardID), Self.offers.map(\.cardId))
        XCTAssertEqual(model.rows.map(\.scoreText), ["115", "103", "—"])
        XCTAssertEqual(model.statusKey, "HearthArena_BaseScore")
    }

    func testLateResultCannotRestoreOldChoicesAfterResetOrDisable() async throws {
        let list = try HearthArenaTierList.parse(HearthArenaTests.fixture(), fetchedAt: Date())
        for disable in [false, true] {
            let model = try model(loader: {
                // Deliberately ignore cancellation, as a coalesced network request may.
                try? await Task.sleep(nanoseconds: 80_000_000)
                return HearthArenaRatingsResult(list: list, isStale: false)
            })
            start(model)
            if disable { model.setEnabled(false) } else { model.reset() }
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertTrue(model.rows.isEmpty)
            XCTAssertFalse(model.isVisible)
        }
    }

    func testNewChoicesReplacePendingOldChoicesAndKeepDuplicatesBySlot() async throws {
        let model = try model()
        start(model)
        model.setChoices((0..<3).map { .init(index: $0, cardId: "JAIL_101") })
        await settle(model)
        XCTAssertEqual(model.rows.map(\.id), [0, 1, 2])
        XCTAssertEqual(model.rows.map(\.scoreText), ["103", "103", "103"])
    }

    func testHeroChoicesDualClassesAndInvalidSlotsDoNotBorrowRatings() async throws {
        let model = try model()
        start(model)
        model.setHeroPower("other-power")
        XCTAssertEqual(model.statusKey, "HearthArena_DualClassUnsupported")
        XCTAssertTrue(model.rows.allSatisfy { $0.score == nil })
        model.setHeroPower("power")
        await settle(model)
        XCTAssertEqual(model.rows.first?.score, 115)
        model.setChoices((0..<3).map { .init(index: $0, cardId: "hero") })
        XCTAssertFalse(model.isVisible)
        model.setChoices((0..<3).map { _ in .init(index: 0, cardId: "JAIL_101") })
        XCTAssertFalse(model.isVisible)
    }

    func testPackageScoreIsForKeyCardAndLeavingDraftHidesIt() async throws {
        let model = try model()
        start(model)
        model.setChoices((0..<3).map { .init(index: $0, cardId: "JAIL_101", packageCardIds: ["CATA_156"]) })
        await settle(model)
        XCTAssertTrue(model.rows.allSatisfy(\.isPackage))
        XCTAssertEqual(model.rows.map(\.scoreText), ["103", "103", "103"])
        model.setClientState(.init(clientState: .normalReady, sessionState: .invalid))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.isVisible)
    }

    func testFailureIsVisibleAndPreferenceCanRestoreCurrentOffers() async throws {
        let model = try model(loader: { throw URLError(.notConnectedToInternet) })
        start(model)
        await settle(model)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.statusKey, "HearthArena_Unavailable")
        XCTAssertTrue(model.rows.allSatisfy { $0.score == nil })
        model.setEnabled(false)
        XCTAssertFalse(model.isVisible)
        model.setEnabled(true)
        await settle(model)
        XCTAssertEqual(model.rows.count, 3)
    }

    func testRenderRatingRowAndArenaPreferences() async throws {
        let model = try model()
        start(model)
        await settle(model)
        let preview = ZStack(alignment: .topLeading) {
            Color(hex: "#24211B")
            HearthArenaRatingRow(rows: model.rows, statusKey: model.statusKey,
                                isVisible: true, alongsideArenasmith: false)
        }.frame(width: 1440, height: 1080)
        let view = NSHostingView(rootView: preview)
        try await render(view, frame: CGRect(x: 0, y: 0, width: 1440, height: 1080),
                         crop: CGRect(x: 100, y: 575, width: 900, height: 190), name: "ratings.png")
        let combined = ZStack(alignment: .topLeading) {
            Color(hex: "#24211B")
            HStack(spacing: 0) {
                ForEach(0..<3) { index in
                    ArenaPlaqueView(viewModel: ArenaPlaqueViewModel(score: ["8", "7.5", "6"][index],
                        level: 2, randomSeed: index, isUnderground: false))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10).frame(width: HearthArenaRatingRow.columnWidth)
            .offset(x: HearthArenaRatingRow.optionsWidth * 0.108, y: 595)
            HearthArenaRatingRow(rows: model.rows, statusKey: model.statusKey,
                                isVisible: true, alongsideArenasmith: true)
        }.frame(width: 1440, height: 1080)
        try await render(NSHostingView(rootView: combined), frame: CGRect(x: 0, y: 0, width: 1440, height: 1080),
                         crop: CGRect(x: 100, y: 575, width: 900, height: 190), name: "ratings-with-arenasmith.png")
        let preferences = ArenaPreferences(nibName: "ArenaPreferences", bundle: Bundle(for: ArenaPreferences.self))
        _ = preferences.view
        preferences.viewWillAppear()
        preferences.view.layoutSubtreeIfNeeded()
        let size = preferences.view.fittingSize
        XCTAssertGreaterThan(size.height, 238)
        try await render(preferences.view, frame: CGRect(origin: .zero, size: size), crop: nil, name: "preferences.png")
    }

    private func render(_ view: NSView, frame: CGRect, crop: CGRect?, name: String) async throws {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let rect = crop ?? view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-HearthArena-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
        window.close()
    }
}
