//
//  HeroPowerQuestCounter.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

class HeroPowerQuestCounter: QuestProgressCounter {

    override var category: QuestProgressCategory {
        return .heroPowerUses
    }

    override var localizedName: String {
        return String.localizedString("Counter_QuestHeroPower", comment: "")
    }

    override var cardIdToShowInUI: String? {
        return CardIds.Collectible.Hunter.ToxicReinforcements
    }

    override var relatedCards: [String] {
        return [
            CardIds.Collectible.Hunter.ToxicReinforcements,
            CardIds.Collectible.Shaman.GlowrootLure
        ]
    }

    required init(controlledByPlayer: Bool, game: Game) {
        super.init(controlledByPlayer: controlledByPlayer, game: game)
    }

    override func handleTagChange(tag: GameTag, entity: Entity, value: Int, prevValue: Int) {
        guard game.isTraditionalHearthstoneMatch else { return }
        guard tag == .num_times_hero_power_used_this_game else { return }
        guard isPlayerControlled(entity) else { return }
        recordProgress(total: value)
    }
}
