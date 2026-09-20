import Foundation

enum AccountQuestLogBridge {
    static func isLocalPlayer(_ entity: Entity, playerID: Int) -> Bool {
        guard playerID > 0 else { return false }
        if entity.has(tag: .player_id) { return entity[.player_id] == playerID }
        return entity.isControlled(by: playerID)
    }
}

extension Game {
    /// Called on the log reader queue after a tag change. Copy values before hopping
    /// to the UI queue; never inspect mutable game entities from the main thread.
    func updateAccountQuestEstimate(tag: GameTag, entityID: Int, value: Int) {
        let metric: AccountQuestEstimate.Metric
        switch tag {
        case .num_times_hero_power_used_this_game: metric = .heroPowerUses
        case .num_resources_spent_this_game: metric = .manaSpent
        default: return
        }
        guard !spectator, !isInMenu, isTraditionalHearthstoneMatch,
              player.id > 0, let entity = entities[entityID] else { return }
        // These cumulative tags belong to a Player entity. Player ownership is
        // PLAYER_ID; unlike cards, it need not carry a CONTROLLER tag.
        let local = AccountQuestLogBridge.isLocalPlayer(entity, playerID: player.id)
        let match = gameId
        DispatchQueue.main.async {
            AccountProgressModel.shared.observeQuest(metric, total: value, matchID: match, isLocalPlayer: local)
        }
    }
}
