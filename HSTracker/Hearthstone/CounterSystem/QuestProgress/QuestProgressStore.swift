//
//  QuestProgressStore.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

enum QuestProgressCategory: String, CaseIterable {
    case heroPowerUses
    case enemyHeroDamage
    case manaSpent
}

// Hearthstone's daily/weekly quest progress is not exposed to HSTracker: the
// HearthMirror framework has no accessor for the quest log, and the Power.log
// only carries the in-game entity state. The quest categories tracked here are
// therefore reconstructed from live game tags, and this store keeps the
// resulting totals across games for the current day so the counters can show
// both the current game's value and the day's running total.
class QuestProgressStore {
    static let shared = QuestProgressStore()

    private static let defaultsKey = "quest_progress_store"
    private static let dayKey = "day"
    private static let totalsKey = "totals"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let lock = UnfairLock()
    private var day = QuestProgressStore.currentDay()
    private var completedTotals: [QuestProgressCategory: Int] = [:]
    private var currentGame: [QuestProgressCategory: Int] = [:]

    init() {
        load()
    }

    private static func currentDay() -> String {
        return dayFormatter.string(from: Date())
    }

    private func rollDayIfNeeded() {
        let today = QuestProgressStore.currentDay()
        if today != day {
            day = today
            completedTotals = [:]
            currentGame = [:]
            save()
        }
    }

    // Value of the category in the game currently being tracked. Only the
    // highest value seen is kept so a reconnect, which replays the whole game
    // state, cannot inflate the total.
    func setCurrentGameValue(_ value: Int, for category: QuestProgressCategory) {
        lock.around {
            rollDayIfNeeded()
            currentGame[category] = max(currentGame[category] ?? 0, value)
        }
    }

    func total(for category: QuestProgressCategory) -> Int {
        return lock.around {
            rollDayIfNeeded()
            return (completedTotals[category] ?? 0) + (currentGame[category] ?? 0)
        }
    }

    func beginGame() {
        lock.around {
            rollDayIfNeeded()
            currentGame = [:]
        }
    }

    func commitGame() {
        lock.around {
            rollDayIfNeeded()
            for (category, value) in currentGame {
                completedTotals[category] = (completedTotals[category] ?? 0) + value
            }
            currentGame = [:]
            save()
        }
    }

    private func load() {
        guard let stored = UserDefaults.standard.dictionary(forKey: QuestProgressStore.defaultsKey),
              let storedDay = stored[QuestProgressStore.dayKey] as? String,
              storedDay == day,
              let totals = stored[QuestProgressStore.totalsKey] as? [String: Int] else {
            return
        }
        for (key, value) in totals {
            if let category = QuestProgressCategory(rawValue: key) {
                completedTotals[category] = value
            }
        }
    }

    private func save() {
        var totals = [String: Int]()
        for (category, value) in completedTotals {
            totals[category.rawValue] = value
        }
        UserDefaults.standard.set([
            QuestProgressStore.dayKey: day,
            QuestProgressStore.totalsKey: totals
        ], forKey: QuestProgressStore.defaultsKey)
    }
}
