//
//  EnemyHeroDamageQuestCounter.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

// Damage dealt by the player to the opposing hero. Hearthstone announces a hit
// with PREDAMAGE on the target, then applies it to ARMOR and/or DAMAGE and
// clears PREDAMAGE again, so the pending amount is only counted once the hit
// actually lands (an immune hero clears PREDAMAGE without either changing).
class EnemyHeroDamageQuestCounter: QuestProgressCounter {

    override var category: QuestProgressCategory {
        return .enemyHeroDamage
    }

    override var localizedName: String {
        return String.localizedString("Counter_QuestEnemyHeroDamage", comment: "")
    }

    override var cardIdToShowInUI: String? {
        return CardIds.Collectible.Mage.Fireball
    }

    override var relatedCards: [String] {
        return [
            CardIds.Collectible.Mage.Fireball,
            CardIds.Collectible.Neutral.LeeroyJenkins
        ]
    }

    private var preDamage = 0

    required init(controlledByPlayer: Bool, game: Game) {
        super.init(controlledByPlayer: controlledByPlayer, game: game)
    }

    override func handleTagChange(tag: GameTag, entity: Entity, value: Int, prevValue: Int) {
        guard game.isTraditionalHearthstoneMatch else { return }
        guard entity.isHero, entity.isControlled(by: game.opponent.id) else { return }

        switch tag {
        case .predamage:
            preDamage = value > 0 ? value : 0
        case .damage where value > prevValue, .armor where value < prevValue:
            guard preDamage > 0, isDealtByPlayer() else { return }
            recordProgress(delta: preDamage)
            preDamage = 0
        default:
            break
        }
    }

    private func isDealtByPlayer() -> Bool {
        if let block = AppDelegate.instance().coreManager.logReaderManager.powerGameStateParser.currentBlock,
           let source = game.entities[block.sourceEntityId] {
            return source.isControlled(by: game.player.id)
        }
        return game.playerEntity?.has(tag: .current_player) ?? false
    }
}
