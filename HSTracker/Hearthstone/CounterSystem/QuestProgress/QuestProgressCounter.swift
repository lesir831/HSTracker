//
//  QuestProgressCounter.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

// Base for the player-side quest progress counters. The chip shows the value
// of the current game followed by the day's running total in parentheses,
// e.g. "3 (12)". Subclasses feed it through recordProgress and are otherwise
// ordinary counters; ReflectionHelper skips this class itself.
class QuestProgressCounter: NumericCounter {

    var category: QuestProgressCategory {
        fatalError("Must override category")
    }

    required init(controlledByPlayer: Bool, game: Game) {
        super.init(controlledByPlayer: controlledByPlayer, game: game)
    }

    override func shouldShow() -> Bool {
        guard isPlayerCounter else { return false }
        guard game.isTraditionalHearthstoneMatch else { return false }
        return Settings.showQuestProgressCounters
    }

    override var hasValue: Bool {
        return true
    }

    override var isDisplayValueLong: Bool {
        return true
    }

    override func getCardsToDisplay() -> [String] {
        return relatedCards
    }

    override func valueToShow() -> String {
        return "\(counter) (\(QuestProgressStore.shared.total(for: category)))"
    }

    func recordProgress(total value: Int) {
        guard isPlayerCounter, value > counter else { return }
        QuestProgressStore.shared.setCurrentGameValue(value, for: category)
        counter = value
    }

    func recordProgress(delta: Int) {
        guard delta > 0 else { return }
        recordProgress(total: counter + delta)
    }

    func isPlayerControlled(_ entity: Entity) -> Bool {
        return entity.isControlled(by: game.player.id)
    }
}
