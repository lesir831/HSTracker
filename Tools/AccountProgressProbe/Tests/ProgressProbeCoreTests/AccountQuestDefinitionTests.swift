import Foundation
import XCTest
@testable import ProgressProbeCore

final class AccountQuestDefinitionTests: XCTestCase {
    func testLegacySnapshotWithoutNativeDefinitionsRemainsReadable() throws {
        let data = Data(#"{"capturedAt":0,"quests":[{"id":84,"progress":3,"status":2}],"achievements":[],"definitions":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(AccountProgressSnapshot.self, from: data)
        XCTAssertEqual(snapshot.quests, [.init(id: 84, progress: 3, status: 2)])
        XCTAssertTrue(snapshot.nativeQuestDefinitions.isEmpty)
    }

    func testNativeLocalizedDefinitionsRoundTripWithSnapshot() throws {
        let definitions = [
            AccountNativeQuestDefinition(id: 84, name: "", description: "使用$q张法术牌。", quota: 25,
                                         rewardTrackType: 1, questPoolID: 1, poolType: 1),
            AccountNativeQuestDefinition(id: 382, name: "", description: "消灭$q个随从。", quota: 500,
                                         rewardTrackType: 2, questPoolID: 18, poolType: 2)
        ]
        let snapshot = AccountProgressSnapshot(capturedAt: Date(timeIntervalSinceReferenceDate: 0),
                                               quests: [.init(id: 84, progress: 3, status: 2)],
                                               achievements: [], definitions: [], nativeQuestDefinitions: definitions)
        let decoded = try JSONDecoder().decode(AccountProgressSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.nativeQuestDefinitions, definitions)
        XCTAssertEqual(decoded.quests, snapshot.quests)
        XCTAssertEqual(decoded.capturedAt, snapshot.capturedAt)
    }

    func testFutureRawTypesAndStatusesArePreservedWithoutInventingAClassification() throws {
        let definition = AccountNativeQuestDefinition(id: 8000, name: "Future", description: "", quota: 7,
                                                      rewardTrackType: 100, questPoolID: 800, poolType: 101)
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: [.init(id: 8000, progress: 1, status: 102)],
                                               achievements: [], definitions: [], nativeQuestDefinitions: [definition])
        let decoded = try JSONDecoder().decode(AccountProgressSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.nativeQuestDefinitions.first?.rewardTrackType, 100)
        XCTAssertEqual(decoded.nativeQuestDefinitions.first?.poolType, 101)
        XCTAssertEqual(decoded.quests.first?.status, 102)
        XCTAssertNil(AccountQuestPoolType(rawValue: 101))
        XCTAssertNil(AccountQuestStatus(rawValue: 102))
    }

    func testMissingPoolTypeRemainsUnknownInsteadOfBecomingDaily() throws {
        let data = Data(#"{"id":84,"name":"","description":"Task","quota":25,"rewardTrackType":1,"questPoolID":1}"#.utf8)
        let definition = try JSONDecoder().decode(AccountNativeQuestDefinition.self, from: data)
        XCTAssertNil(definition.poolType)
        XCTAssertEqual(AccountQuestPoolType.daily.rawValue, 1)
        XCTAssertEqual(AccountQuestPoolType.weekly.rawValue, 2)
        XCTAssertEqual(AccountQuestPoolType.event.rawValue, 3)
        XCTAssertEqual(AccountQuestStatus.new.rawValue, 1)
        XCTAssertEqual(AccountQuestStatus.active.rawValue, 2)
        XCTAssertEqual(AccountQuestStatus.expired.rawValue, 9)
    }
}
