import Foundation

/// DAMAGE metadata confirms a hit after PREDAMAGE has already returned to zero.
/// Keep packet parsing separate so log replays exercise the real wire order.
struct AccountQuestDamageMetadata {
    private static let header = Regex("META_DATA - Meta=DAMAGE Data=(\\d+) Info(?:Count)?=(\\d+)")
    private static let info = Regex("Info\\[(\\d+)\\]\\s*=\\s*(?:.*\\bid=(\\d+).*]|\\b(\\d+)\\b)")
    private var amount = 0
    private var count = 0
    private var seen = Set<Int>()

    mutating func read(_ line: String) -> (entityID: Int, amount: Int)? {
        let header = Self.header.matches(line)
        if header.count == 2 {
            amount = Int(header[0].value) ?? 0
            count = Int(header[1].value) ?? 0
            seen.removeAll()
            return nil
        }
        let info = Self.info.matches(line)
        guard !info.isEmpty else {
            amount = 0; count = 0; seen.removeAll()
            return nil
        }
        guard amount > 0, let index = Int(info[0].value), index < count,
              let entityID = info.dropFirst().compactMap({ Int($0.value) }).first,
              seen.insert(index).inserted else { return nil }
        return (entityID, amount)
    }
}

enum AccountQuestLogBridge {
    static func context(gameType: GameType, playerClass: CardClass?) -> AccountQuestEstimate.Context {
        let brawl: Bool
        switch gameType {
        case .gt_tavernbrawl, .gt_tb_1p_vs_ai, .gt_tb_2p_coop, .gt_fsg_brawl_vs_friend,
             .gt_fsg_brawl, .gt_fsg_brawl_1p_vs_ai, .gt_fsg_brawl_2p_coop: brawl = true
        default: brawl = false
        }
        return .init(ranked: gameType == .gt_ranked, playerClass: playerClass?.rawValue ?? "", tavernBrawl: brawl)
    }

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
        // Summoned entities may have a granted or removed Deathrattle.
        if let deathrattle = entity.tags[.deathrattle] {
            if deathrattle > 0 { keywords.insert("DEATHRATTLE") }
            else { keywords.remove("DEATHRATTLE") }
        }
        return .init(type: entity.has(tag: .cardtype) ? entity[.cardtype] : card.type.rawValue,
                     cost: entity.tags[.cost] ?? card.cost,
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
        var handCount = 0
        var maxHandSize = 10
        var localPlayState = PlayState.playing
    }

    enum Sample {
        case cumulative(AccountQuestEstimate.Metric, Int)
        case action(AccountQuestEstimate.Event, String)
    }

    private var serial = 0
    private var plays: [Int: AccountQuestEstimate.CardFacts] = [:]
    private var purchases: [Int: Int] = [:]
    private struct HeroDamage {
        let blockID: Int?
        var remaining: Int
        let localSource: Bool
        let ownTurn: Bool
    }
    private var heroDamage: [Int: HeroDamage] = [:]
    private var drawsByTurn: [Int: Int] = [:]
    private var manaSpent = 0
    private var attacksByTurn: [Int: [Int: Int]] = [:]
    private struct DrawBatch {
        var count = 0
        var cards: [AccountQuestEstimate.CardFacts] = []
    }
    private var drawsByBlock: [Int: DrawBatch] = [:]
    private var drawTurn: Int?
    private var burnedCardIDs = Set<String>()
    private var increasedStats: [Int: [Int: Set<GameTag>]] = [:]
    private var silencedInBlock: [Int: Set<Int>] = [:]

    func reset() {
        serial = 0
        plays.removeAll()
        purchases.removeAll()
        heroDamage.removeAll()
        drawsByTurn.removeAll()
        manaSpent = 0
        attacksByTurn.removeAll()
        drawsByBlock.removeAll()
        drawTurn = nil
        burnedCardIDs.removeAll()
        increasedStats.removeAll()
        silencedInBlock.removeAll()
    }

    private func action(_ event: AccountQuestEstimate.Event) -> Sample {
        serial += 1
        return .action(event, "tag:\(serial)")
    }

    private func rootID(_ block: Block?) -> Int {
        guard var root = block else { return 0 }
        while let parent = root.parent { root = parent }
        return root.id
    }

    /// Pair a draw tag with the card moved out of the deck in either log order.
    /// A deck move alone (e.g. a mill) never earns a draw bonus.
    private func drawSamples(block: Block?, count: Int = 0,
                             card: AccountQuestEstimate.CardFacts? = nil) -> [Sample] {
        let id = rootID(block)
        var batch = drawsByBlock[id] ?? DrawBatch()
        batch.count += count
        if let card { batch.cards.append(card) }
        var result: [Sample] = []
        while batch.count > 0 && !batch.cards.isEmpty {
            result.append(action(.drawn(batch.cards.removeFirst())))
            batch.count -= 1
        }
        drawsByBlock[id] = batch
        return result
    }

    private func beginDrawTurn(_ turn: Int) {
        if drawTurn != turn {
            drawsByBlock.removeAll()
            drawTurn = turn
        }
    }

    func burnedCard(_ entity: Entity, block: Block?, context: Context) -> [Sample] {
        guard !context.battlegrounds, context.mulliganDone, context.playerID > 0,
              entity.isControlled(by: context.playerID) else { return [] }
        beginDrawTurn(context.turn)
        let id = "burn:\(context.turn):\(rootID(block)):\(entity.id)"
        guard burnedCardIDs.insert(id).inserted else { return [] }
        return drawSamples(block: block, card: AccountQuestLogBridge.facts(entity))
    }

    func blockEnded(_ block: Block) {
        heroDamage = heroDamage.filter { $0.value.blockID != block.id }
        increasedStats.removeValue(forKey: block.id)
        silencedInBlock.removeValue(forKey: block.id)
        if block.parent == nil { drawsByBlock.removeValue(forKey: block.id) }
    }

    func damageStarted(_ entity: Entity, amount: Int, block: Block?, context: Context) {
        guard entity.isHero, amount > 0, context.playerID > 0 else { return }
        heroDamage[entity.id] = HeroDamage(blockID: block?.id, remaining: amount,
            localSource: damageIsLocal(target: entity, block: block, context: context), ownTurn: context.localTurn)
    }

    private func paymentCard(_ block: Block?, context: Context) -> AccountQuestEstimate.CardFacts? {
        var ancestor = block
        while let candidate = ancestor {
            if candidate.type == "PLAY", let source = context.entity(candidate.sourceEntityId),
               source.isControlled(by: context.playerID) {
                return plays[candidate.id] ?? AccountQuestLogBridge.facts(source)
            }
            ancestor = candidate.parent
        }
        return nil
    }

    func choiceCompleted(_ choice: IHsCompletedChoice, context: Context) -> [Sample] {
        guard !context.battlegrounds, context.playerID > 0, context.mulliganDone,
              choice.choiceType == .general, let offered = choice.offeredEntityIds else { return [] }
        let source = context.entity(choice.sourceEntityId)
        let sourceDiscovers = (source?[.discover] ?? 0) > 0 || source?.card.mechanics.contains("DISCOVER") == true
        return Set(choice.chosenEntityIds ?? []).sorted().compactMap { id in
            guard offered.contains(id), let chosen = context.entity(id), chosen.isPlayableCard,
                  chosen[.was_discover_option] > 0 || sourceDiscovers else { return nil }
            return .action(.discovered(AccountQuestLogBridge.facts(chosen)), "discover:\(choice.id):\(id)")
        }
    }

    func matchEnded(result: GameResult, context: Context) -> [Sample] {
        guard !context.battlegrounds, context.playerID > 0,
              result != .unknown || context.localPlayState == .conceded else { return [] }
        // Credit only a final result, never match start or a disconnect. Server
        // settlement can reject a short concession and replaces this estimate.
        return [.action(.matchCompleted(won: result == .win), "match-result")]
    }

    func blockStarted(_ block: Block, context: Context) -> [Sample] {
        heroDamage = heroDamage.filter { $0.value.blockID != nil }
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
            return [.action(.add(.deathrattles, 1), "deathrattle:\(block.id)"),
                    .action(.deathrattleTriggered(AccountQuestLogBridge.facts(source)), "event-deathrattle:\(block.id)")]
        }
        return []
    }

    func tagChanged(_ tag: GameTag, entity: Entity, value: Int, previous: Int,
                    block: Block?, context: Context, isCreationTag: Bool = false) -> [Sample] {
        guard context.playerID > 0, value != previous else { return [] }
        beginDrawTurn(context.turn)
        let local = AccountQuestLogBridge.isLocalPlayer(entity, playerID: context.playerID)
        if entity.isHero, tag == .predamage, value > 0 {
            // A new attempt cannot inherit an unapplied earlier hit.
            heroDamage.removeValue(forKey: entity.id)
        }
        if entity.isHero, !isCreationTag, [.damage, .armor].contains(tag),
           var hit = heroDamage[entity.id], hit.blockID == block?.id {
            let applied = max(0, tag == .damage ? value - previous : previous - value)
            if applied > 0 {
                let amount = min(applied, hit.remaining)
                hit.remaining -= amount
                heroDamage[entity.id] = hit.remaining > 0 && tag == .armor ? hit : nil
                if entity.isControlled(by: context.opponentID), hit.localSource {
                    return [action(.add(.enemyHeroDamage, amount))]
                }
                if local, !context.battlegrounds, context.mulliganDone {
                    let damage = tag == .damage ? min(amount, max(0, entity[.health] - previous)) : amount
                    if damage > 0 { return [action(.damageTaken(damage, ownTurn: hit.ownTurn))] }
                }
            }
        }
        if local {
            switch tag {
            case .num_times_hero_power_used_this_game: return [.cumulative(.heroPowerUses, value)]
            case .num_resources_spent_this_game:
                let amount = max(0, value - manaSpent)
                manaSpent = max(manaSpent, value)
                var samples: [Sample] = [.cumulative(.manaSpent, value)]
                if amount > 0, let card = paymentCard(block, context: context) {
                    samples.append(action(.manaSpentOn(card, amount)))
                }
                return samples
            case .num_cards_drawn_this_turn where context.mulliganDone && !context.battlegrounds:
                let prior = drawsByTurn[context.turn] ?? 0
                guard value > prior else { return [] }
                drawsByTurn[context.turn] = value
                return [action(.add(.cardsDrawn, value - prior))] + drawSamples(block: block, count: value - prior)
            case .num_attacks_this_turn where context.mulliganDone && !context.battlegrounds && (entity.isMinion || entity.isHero):
                let prior = attacksByTurn[context.turn]?[entity.id] ?? 0
                guard value > prior else { return [] }
                attacksByTurn[context.turn, default: [:]][entity.id] = value
                return [action(.attacked(AccountQuestLogBridge.facts(entity), value - prior))]
            case .player_tech_level where context.battlegrounds && previous > 0 && value > previous:
                return [action(.add(.tavernUpgrades, value - previous))]
            case .divine_shield where context.battlegrounds && context.combat && previous > 0 && value == 0:
                // Silence/removal is not a shield absorbing damage.
                if entity[.predamage] > 0 { return [action(.add(.divineShields, 1))] }
            default: break
            }
        }
        if !context.battlegrounds && context.mulliganDone {
            if tag == .silenced, value > 0, let block {
                silencedInBlock[block.id, default: []].insert(entity.id)
            }
            if local && entity.isMinion && [.atk, .health].contains(tag), value > previous,
               !isCreationTag, let block, ["POWER", "TRIGGER"].contains(block.type ?? ""),
               !silencedInBlock[block.id, default: []].contains(entity.id),
               let source = context.entity(block.sourceEntityId), source.isControlled(by: context.playerID),
               source[.silence] == 0, !source.card.mechanics.contains("SILENCE") {
                var tags = increasedStats[block.id]?[entity.id] ?? []
                // +attack and +health from one buff count once. A repeated
                // increase of the same stat starts another application.
                let newBuff = tags.isEmpty || tags.contains(tag)
                if newBuff { tags.removeAll() }
                tags.insert(tag)
                increasedStats[block.id, default: [:]][entity.id] = tags
                if newBuff { return [action(.statsIncreased)] }
            }
        }
        if tag == .step, value == Step.main_start.rawValue, context.localTurn,
           context.mulliganDone && !context.battlegrounds && context.turn > 0 {
            // CURRENT_PLAYER can be set before the mulligan, and extra turns
            // need not alternate players. Count the actual start once per turn.
            return [.action(.add(.turnsTaken, 1), "turn:\(context.turn)")] + fullHandSamples(context)
        }
        if [.maxhandsize, .controller].contains(tag) { return fullHandSamples(context) }
        guard tag == .zone else { return [] }
        var samples: [Sample] = []
        if local && context.mulliganDone && !context.battlegrounds && previous == Zone.deck.rawValue,
           value == Zone.hand.rawValue || (value == Zone.play.rawValue && entity[.casts_when_drawn] > 0) {
            samples += drawSamples(block: block, card: AccountQuestLogBridge.facts(entity))
        }
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
            samples.append(action(.destroyed(AccountQuestLogBridge.facts(entity))))
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
        return samples + fullHandSamples(context)
    }

    private func fullHandSamples(_ context: Context) -> [Sample] {
        guard !context.battlegrounds, context.mulliganDone,
              context.maxHandSize > 0, context.handCount >= context.maxHandSize else { return [] }
        return [.action(.handFilled, "full-hand")]
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
        .step, .player_tech_level, .divine_shield, .predamage, .damage, .armor, .zone,
        .atk, .health, .silenced, .num_attacks_this_turn, .maxhandsize, .controller
    ]

    private var accountQuestContext: AccountQuestLogTracker.Context {
        .init(playerID: player.id, opponentID: opponent.id, mulliganDone: isMulliganDone(),
              battlegrounds: isBattlegroundsMatch(), combat: isBattlegroundsCombatPhase,
              turn: gameEntity?[.turn] ?? 0, defenderID: proposedDefenderEntityId,
              entity: { self.entities[$0] }, localTurn: playerEntity?[.current_player] == 1,
              handCount: player.handCount, maxHandSize: playerEntity?.tags[.maxhandsize] ?? 10,
              localPlayState: PlayState(rawValue: playerEntity?[.playstate] ?? 0) ?? .invalid)
    }

    private var canEstimateAccountQuests: Bool {
        !isInMenu && !spectator && player.id > 0 && AccountQuestLogBridge.isEligible(gameType: currentGameType)
    }

    func updateAccountQuestBlock(_ block: Block) {
        guard canEstimateAccountQuests else { return }
        publishQuestSamples(accountQuestLogTracker.blockStarted(block, context: accountQuestContext))
    }

    func endAccountQuestBlock(_ block: Block) {
        accountQuestLogTracker.blockEnded(block)
    }

    func updateAccountQuestChoice(_ choice: IHsCompletedChoice) {
        guard canEstimateAccountQuests else { return }
        publishQuestSamples(accountQuestLogTracker.choiceCompleted(choice, context: accountQuestContext))
    }

    func updateAccountQuestBurn(_ entity: Entity, block: Block?) {
        guard canEstimateAccountQuests else { return }
        publishQuestSamples(accountQuestLogTracker.burnedCard(entity, block: block, context: accountQuestContext))
    }

    func updateAccountQuestDamage(entityID: Int, amount: Int, block: Block?) {
        guard canEstimateAccountQuests, let entity = entities[entityID] else { return }
        accountQuestLogTracker.damageStarted(entity, amount: amount, block: block, context: accountQuestContext)
    }

    func completeAccountQuestMatch() {
        guard canEstimateAccountQuests else { return }
        publishQuestSamples(accountQuestLogTracker.matchEnded(result: gameResult, context: accountQuestContext))
    }

    func updateAccountQuestEstimate(tag: GameTag, entityID: Int, value: Int, previous: Int, block: Block?,
                                    isCreationTag: Bool = false) {
        guard Self.accountQuestTags.contains(tag), canEstimateAccountQuests, let entity = entities[entityID] else { return }
        publishQuestSamples(accountQuestLogTracker.tagChanged(tag, entity: entity, value: value,
            previous: previous, block: block, context: accountQuestContext, isCreationTag: isCreationTag))
    }

    private func publishQuestSamples(_ samples: [AccountQuestLogTracker.Sample]) {
        guard !samples.isEmpty else { return }
        let match = gameId
        let context = AccountQuestLogBridge.context(gameType: currentGameType, playerClass: player.originalClass)
        DispatchQueue.main.async {
            for sample in samples {
                switch sample {
                case .cumulative(let metric, let value):
                    AccountProgressModel.shared.observeQuest(metric, total: value, matchID: match,
                        isLocalPlayer: true, context: context)
                case .action(let event, let id):
                    AccountProgressModel.shared.observeQuest(event, eventID: id, matchID: match, context: context)
                }
            }
        }
    }
}
