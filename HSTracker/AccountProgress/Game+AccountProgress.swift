import Foundation

enum AccountQuestLogBridge {
    static func isEligible(gameType: GameType) -> Bool {
        switch gameType {
        case .gt_ranked, .gt_casual, .gt_vs_friend, .gt_arena, .gt_underground_arena,
             .gt_tavernbrawl, .gt_tb_1p_vs_ai, .gt_tb_2p_coop, .gt_fsg_brawl_vs_friend,
             .gt_fsg_brawl, .gt_fsg_brawl_1p_vs_ai, .gt_fsg_brawl_2p_coop,
             .gt_battlegrounds, .gt_battlegrounds_friendly, .gt_battlegrounds_duo, .gt_battlegrounds_duo_friendly:
            return true
        default: return false
        }
    }

    static func isLocalPlayer(_ entity: Entity, playerID: Int) -> Bool {
        guard playerID > 0 else { return false }
        if entity.has(tag: .player_id) { return entity[.player_id] == playerID }
        return entity.isControlled(by: playerID)
    }

    static func facts(_ entity: Entity) -> AccountQuestEstimate.CardFacts {
        let card = entity.card
        var keywords = card.accountQuestKeywords
        // Use current entity keywords for effects granted to the played card.
        for (tag, keyword) in [(GameTag.battlecry, "BATTLECRY"), (.herald, "HERALD"),
                               (.shattered, "SHATTERED"), (.colossal, "COLOSSAL")] where entity[tag] > 0 {
            keywords.insert(keyword)
        }
        return .init(type: entity.has(tag: .cardtype) ? entity[.cardtype] : card.type.rawValue,
                     cost: entity.has(tag: .cost) ? entity[.cost] : card.cost,
                     set: card.set?.rawValue ?? "", races: Set(card.races.map(\.rawValue)),
                     school: entity.has(tag: .spell_school) ? entity[.spell_school] : card.spellSchool.rawValue,
                     keywords: keywords, legendary: card.rarity == .legendary,
                     golden: entity[.premium] == 1 || card.baconTriple,
                     tier: entity.has(tag: .tech_level) ? entity[.tech_level] : card.techLevel)
    }
}

/// Owned exclusively by the log queue. It returns value samples; the UI queue
/// never reads a mutable Entity or Block. Keeping this independent of the global
/// app/model also lets replay tests exercise the actual ownership and event path.
final class AccountQuestLogTracker {
    struct Context {
        let playerID: Int
        let opponentID: Int
        let mulliganDone: Bool
        let battlegrounds: Bool
        let combat: Bool
        let turn: Int
        let defenderID: Int
        let entity: (Int) -> Entity?
        var localTurn = false
    }

    enum Sample {
        case cumulative(AccountQuestEstimate.Metric, Int)
        case action(AccountQuestEstimate.Event, String)
    }

    private var serial = 0
    private var plays: [Int: AccountQuestEstimate.CardFacts] = [:]
    private var purchases: [Int: Int] = [:]
    private var playerDamage = Set<Int>()
    private var drawsByTurn: [Int: Int] = [:]

    func reset() {
        serial = 0
        plays.removeAll()
        purchases.removeAll()
        playerDamage.removeAll()
        drawsByTurn.removeAll()
    }

    private func action(_ event: AccountQuestEstimate.Event) -> Sample {
        serial += 1
        return .action(event, "tag:\(serial)")
    }

    func blockStarted(_ block: Block, context: Context) -> [Sample] {
        guard context.playerID > 0, let source = context.entity(block.sourceEntityId) else { return [] }
        // Buying uses a PLAY block for a card on Bob's side, followed by its
        // transfer into our hand. There is no BUY block type in the protocol.
        // A generated card, a bounce or a hero-power theft has a different source.
        if context.battlegrounds && !context.combat && block.type == "PLAY",
           source.isInPlay, source.isControlled(by: context.opponentID), source.isPlayableCard {
            purchases[block.id] = source.id
        }
        guard source.isControlled(by: context.playerID) else { return [] }
        if block.type == "PLAY", source.isInHand, source.isPlayableCard,
           source[.is_using_trade_option] == 0, !context.battlegrounds || !context.combat {
            // Capture discounted cost and card identity before play resets tags
            // or transforms the entity. The subsequent zone change proves a play.
            plays[block.id] = AccountQuestLogBridge.facts(source)
        }
        if block.type == "TRIGGER", block.triggerKeyword == "DEATHRATTLE" {
            return [.action(.add(.deathrattles, 1), "deathrattle:\(block.id)")]
        }
        return []
    }

    func tagChanged(_ tag: GameTag, entity: Entity, value: Int, previous: Int,
                    block: Block?, context: Context) -> [Sample] {
        guard context.playerID > 0, value != previous else { return [] }
        let local = AccountQuestLogBridge.isLocalPlayer(entity, playerID: context.playerID)
        if local {
            switch tag {
            case .num_times_hero_power_used_this_game: return [.cumulative(.heroPowerUses, value)]
            case .num_resources_spent_this_game: return [.cumulative(.manaSpent, value)]
            case .num_cards_drawn_this_turn where context.mulliganDone && !context.battlegrounds:
                let prior = drawsByTurn[context.turn] ?? 0
                guard value > prior else { return [] }
                drawsByTurn[context.turn] = value
                return [action(.add(.cardsDrawn, value - prior))]
            case .player_tech_level where context.battlegrounds && previous > 0 && value > previous:
                return [action(.add(.tavernUpgrades, value - previous))]
            case .divine_shield where context.battlegrounds && context.combat && previous > 0 && value == 0:
                // Silence/removal is not a shield absorbing damage.
                if entity[.predamage] > 0 { return [action(.add(.divineShields, 1))] }
            default: break
            }
        }
        if tag == .step, value == Step.main_start.rawValue, context.localTurn,
           context.mulliganDone && !context.battlegrounds && context.turn > 0 {
            // CURRENT_PLAYER can be set before the mulligan, and extra turns
            // need not alternate players. Count the actual start once per turn.
            return [.action(.add(.turnsTaken, 1), "turn:\(context.turn)")]
        }
        if entity.isHero, entity.isControlled(by: context.opponentID) {
            if tag == .predamage {
                playerDamage.remove(entity.id)
                if value > 0 && damageIsLocal(target: entity, block: block, context: context) {
                    playerDamage.insert(entity.id)
                }
            }
            if playerDamage.contains(entity.id) {
                // Count applied health and armor loss separately. This excludes
                // immune hits, healing and armor removal, and never adds PREDAMAGE
                // twice when one hit crosses from armor into health.
                let amount = tag == .damage ? value - previous : tag == .armor ? previous - value : 0
                if amount > 0 { return [action(.add(.enemyHeroDamage, amount))] }
            }
        }
        guard tag == .zone else { return [] }
        var samples: [Sample] = []
        if previous == Zone.hand.rawValue, [Zone.play.rawValue, Zone.secret.rawValue, Zone.graveyard.rawValue].contains(value) {
            var ancestor = block
            while let candidate = ancestor {
                if candidate.type == "PLAY", candidate.sourceEntityId == entity.id,
                   let facts = plays.removeValue(forKey: candidate.id) {
                    samples.append(.action(.played(facts), "play:\(candidate.id)"))
                    break
                }
                ancestor = candidate.parent
            }
        }
        if local && entity.isMinion && value == Zone.play.rawValue && previous != Zone.play.rawValue && !context.battlegrounds {
            samples.append(action(.summoned(AccountQuestLogBridge.facts(entity))))
        }
        if entity.isMinion && previous == Zone.play.rawValue && value == Zone.graveyard.rawValue,
           entity.health <= 0 || entity[.to_be_destroyed] > 0,
           !context.battlegrounds || context.combat,
           local || entity.isControlled(by: context.opponentID) {
            samples.append(action(.add(.minionsDestroyed, 1)))
        }
        if local && context.battlegrounds && !context.combat && value == Zone.hand.rawValue {
            var ancestor = block
            while let candidate = ancestor {
                if purchases[candidate.id] == entity.id {
                    purchases.removeValue(forKey: candidate.id)
                    samples.append(.action(.add(.cardsBought, 1), "buy:\(candidate.id):\(entity.id)"))
                    break
                }
                ancestor = candidate.parent
            }
        }
        return samples
    }

    private func damageIsLocal(target: Entity, block: Block?, context: Context) -> Bool {
        guard let block else { return false }
        if block.type == "FATIGUE" { return false }
        if block.type == "ATTACK", block.sourceEntityId == target.id {
            // An enemy hero attacking our minion takes our retaliation damage.
            return context.entity(context.defenderID)?.isControlled(by: context.playerID) == true
        }
        guard let source = context.entity(block.sourceEntityId) else { return false }
        return source.isControlled(by: context.playerID)
    }
}

extension Game {
    private static let accountQuestTags: Set<GameTag> = [
        .num_times_hero_power_used_this_game, .num_resources_spent_this_game, .num_cards_drawn_this_turn,
        .step, .player_tech_level, .divine_shield, .predamage, .damage, .armor, .zone
    ]

    private var accountQuestContext: AccountQuestLogTracker.Context {
        .init(playerID: player.id, opponentID: opponent.id, mulliganDone: isMulliganDone(),
              battlegrounds: isBattlegroundsMatch(), combat: isBattlegroundsCombatPhase,
              turn: gameEntity?[.turn] ?? 0, defenderID: proposedDefenderEntityId,
              entity: { self.entities[$0] }, localTurn: playerEntity?[.current_player] == 1)
    }

    private var canEstimateAccountQuests: Bool {
        !isInMenu && !spectator && player.id > 0 && AccountQuestLogBridge.isEligible(gameType: currentGameType)
    }

    func updateAccountQuestBlock(_ block: Block) {
        guard canEstimateAccountQuests else { return }
        publishQuestSamples(accountQuestLogTracker.blockStarted(block, context: accountQuestContext))
    }

    func updateAccountQuestEstimate(tag: GameTag, entityID: Int, value: Int, previous: Int, block: Block?) {
        guard Self.accountQuestTags.contains(tag), canEstimateAccountQuests, let entity = entities[entityID] else { return }
        publishQuestSamples(accountQuestLogTracker.tagChanged(tag, entity: entity, value: value,
                                                             previous: previous, block: block, context: accountQuestContext))
    }

    private func publishQuestSamples(_ samples: [AccountQuestLogTracker.Sample]) {
        guard !samples.isEmpty else { return }
        let match = gameId
        DispatchQueue.main.async {
            for sample in samples {
                switch sample {
                case .cumulative(let metric, let value):
                    AccountProgressModel.shared.observeQuest(metric, total: value, matchID: match, isLocalPlayer: true)
                case .action(let event, let id):
                    AccountProgressModel.shared.observeQuest(event, eventID: id, matchID: match)
                }
            }
        }
    }
}
