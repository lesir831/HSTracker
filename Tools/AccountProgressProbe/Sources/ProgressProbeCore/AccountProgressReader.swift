import Foundation

public struct AccountProgressRecord: Codable, Equatable, Identifiable {
    public let id: Int
    public let progress: Int
    public let status: Int

    public init(id: Int, progress: Int, status: Int) {
        self.id = id
        self.progress = progress
        self.status = status
    }
}

/// Values verified from the installed client's QuestStatus metadata. The record
/// retains its raw integer so future values are never silently treated as active.
public enum AccountQuestStatus: Int, Codable {
    case unknown = 0, new = 1, active = 2, completed = 3
    case rewardGranted = 4, rewardAcked = 5, rerolled = 6, reset = 7, abandoned = 8, expired = 9
}

public enum AccountQuestPoolType: Int, Codable {
    case none = 0, daily = 1, weekly = 2, event = 3
}

/// The game's own quest DBF and quest-pool metadata, joined only for quest IDs
/// present in the server snapshot. Strings use the client's active locale.
public struct AccountNativeQuestDefinition: Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String
    public let quota: Int
    public let rewardTrackType: Int
    public let questPoolID: Int
    public let poolType: Int?
    /// Membership in the client's quest chain, including its terminal quest.
    /// Nil means the optional chain metadata was unavailable (including old caches).
    public let isChainQuest: Bool?

    public init(id: Int, name: String, description: String, quota: Int,
                rewardTrackType: Int, questPoolID: Int, poolType: Int?, isChainQuest: Bool? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.quota = quota
        self.rewardTrackType = rewardTrackType
        self.questPoolID = questPoolID
        self.poolType = poolType
        self.isChainQuest = isChainQuest
    }
}

public struct AccountAchievementDefinition: Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String
    public let quota: Int
    public let nextId: Int
}

public struct AccountProgressSnapshot: Codable {
    public let capturedAt: Date
    public let quests: [AccountProgressRecord]
    public let achievements: [AccountProgressRecord]
    public let definitions: [AccountAchievementDefinition]
    public let nativeQuestDefinitions: [AccountNativeQuestDefinition]

    public init(capturedAt: Date, quests: [AccountProgressRecord], achievements: [AccountProgressRecord],
                definitions: [AccountAchievementDefinition],
                nativeQuestDefinitions: [AccountNativeQuestDefinition] = []) {
        self.capturedAt = capturedAt
        self.quests = quests
        self.achievements = achievements
        self.definitions = definitions
        self.nativeQuestDefinitions = nativeQuestDefinitions
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, quests, achievements, definitions, nativeQuestDefinitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        quests = try container.decode([AccountProgressRecord].self, forKey: .quests)
        achievements = try container.decode([AccountProgressRecord].self, forKey: .achievements)
        definitions = try container.decode([AccountAchievementDefinition].self, forKey: .definitions)
        nativeQuestDefinitions = try container.decodeIfPresent([AccountNativeQuestDefinition].self,
                                                                forKey: .nativeQuestDefinitions) ?? []
    }
}

public struct AccountProgressReading {
    public let snapshot: AccountProgressSnapshot?
    public let inGame: [Int: Int]
}

/// Confine to one queue. Cache only Mono metadata, never managed service instances.
public final class AccountProgressReader {
    private let memory: RemoteMemory
    private let runtime: MonoRuntime
    public let runtimeUUID: String

    public init(pid: Int32) throws {
        memory = try RemoteMemory(pid: pid)
        let module = try memory.monoModule()
        guard try memory.uint(at: module.address + 4, width: 4) == BinaryImage.arm64 else {
            throw ProbeError.unavailable("unsupportedArchitecture: only native ARM64 is validated")
        }
        let image = try BinaryImage(data: Data(contentsOf: URL(fileURLWithPath: module.path)), cpu: BinaryImage.arm64)
        runtimeUUID = image.uuid
        let pc = module.address + image.rootDomainOffset
        let pointer = try BinaryImage.rootPointerAddress(instructions: memory.data(at: pc, count: 12), pc: pc)
        let root = try memory.uint(at: pointer)
        guard root != 0 else { throw ProbeError.unavailable("monoNotInitialized") }
        runtime = try MonoRuntime(memory: memory, root: root, uuid: image.uuid)
        try runtime.prepare()
    }

    public func read(includeSnapshot: Bool) throws -> AccountProgressReading {
        memory.beginRead()
        var snapshot: AccountProgressSnapshot?
        if includeSnapshot {
            let quests = try records(runtime.readQuests())
            let nativeDefinitions: [AccountNativeQuestDefinition]
            do {
                nativeDefinitions = try runtime.readQuestDefinitions(ids: Set(quests.map(\.id)))
            } catch ProbeError.unavailable {
                // Missing/uninitialized optional DBF data must not hide verified
                // server progress. Corrupt layouts still propagate as invalid.
                nativeDefinitions = []
            }
            snapshot = AccountProgressSnapshot(capturedAt: Date(),
                quests: quests,
                achievements: try records(runtime.readAchievements()),
                definitions: try runtime.readAchievementDefinitions(),
                nativeQuestDefinitions: nativeDefinitions)
        }
        var inGame: [Int: Int] = [:]
        for raw in try runtime.readInGameAchievements() {
            guard let id = raw["id"], let progress = raw["progress"], inGame[id] == nil else {
                throw ProbeError.invalid("Invalid or duplicate in-game record")
            }
            inGame[id] = progress
        }
        return AccountProgressReading(snapshot: snapshot, inGame: inGame)
    }

    private func records(_ raw: [[String: Int]]) throws -> [AccountProgressRecord] {
        var ids = Set<Int>()
        return try raw.map { row in
            guard let id = row["id"], let progress = row["progress"], let status = row["status"], ids.insert(id).inserted else {
                throw ProbeError.invalid("Invalid or duplicate account record")
            }
            return AccountProgressRecord(id: id, progress: progress, status: status)
        }
    }
}
