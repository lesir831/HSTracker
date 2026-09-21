import Foundation

/// The client quest pool determines cadence. Reward tracks and objective text
/// cannot distinguish daily, weekly and event quests.
enum AccountQuestSchedule: String, Codable {
    case daily, weekly, event, unknown

    init(poolType: Int?) {
        switch poolType {
        case 1: self = .daily
        case 2: self = .weekly
        case 3: self = .event
        default: self = .unknown
        }
    }
}

struct AccountQuestDefinitions: Decodable { let quests: [AccountQuestDefinition] }

struct AccountQuestDefinition: Decodable, Equatable {
    let id: Int
    let description: String
    let quota: Int
    let rewardTrackType: Int
    let name: String
    let schedule: AccountQuestSchedule
    let isChainQuest: Bool?

    init(id: Int, description: String, quota: Int, rewardTrackType: Int,
         name: String = "", schedule: AccountQuestSchedule = .unknown, isChainQuest: Bool? = nil) {
        self.id = id
        self.description = description
        self.quota = quota
        self.rewardTrackType = rewardTrackType
        self.name = name
        self.schedule = schedule
        self.isChainQuest = isChainQuest
    }

    private enum CodingKeys: String, CodingKey {
        case id, description, quota, rewardTrackType, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        description = try container.decode(String.self, forKey: .description)
        quota = try container.decode(Int.self, forKey: .quota)
        rewardTrackType = try container.decode(Int.self, forKey: .rewardTrackType)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // The public fallback has no cadence metadata. Never infer it from
        // quest IDs, quota, reward XP or translated objective descriptions.
        schedule = .unknown
        isChainQuest = nil
    }

    var text: String { description.replacingOccurrences(of: "$q", with: String(quota)) }
    var isEvent: Bool { rewardTrackType == 7 || schedule == .event }
}
