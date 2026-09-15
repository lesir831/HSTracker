//
//  ManaSpentQuestCounter.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

class ManaSpentQuestCounter: QuestProgressCounter {

    override var category: QuestProgressCategory {
        return .manaSpent
    }

    override var localizedName: String {
        return String.localizedString("Counter_QuestManaSpent", comment: "")
    }

    override var cardIdToShowInUI: String? {
        return CardIds.Collectible.Mage.LearnDraconic
    }

    override var relatedCards: [String] {
        return [
            CardIds.Collectible.Mage.LearnDraconic,
            CardIds.Collectible.Druid.StrengthInNumbers,
            CardIds.Collectible.Neutral.FrostGiant
        ]
    }

    required init(controlledByPlayer: Bool, game: Game) {
        super.init(controlledByPlayer: controlledByPlayer, game: game)
    }

    override func handleTagChange(tag: GameTag, entity: Entity, value: Int, prevValue: Int) {
        guard game.isTraditionalHearthstoneMatch else { return }
        guard tag == .num_resources_spent_this_game else { return }
        guard isPlayerControlled(entity) else { return }
        recordProgress(total: value)
    }
}
