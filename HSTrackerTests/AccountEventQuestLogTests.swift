import XCTest
@testable import HSTracker

@MainActor
final class AccountEventQuestLogTests: XCTestCase {
    private final class Harness {
        let tracker = AccountQuestLogTracker()
        var estimate = AccountQuestEstimate()
        var entities: [Int: Entity] = [:]
        var turn = 3
        var ownTurn = true
        var handCount = 0
        var handLimit = 10
        var mulliganDone = true
        var battlegrounds = false
        var bonus = AccountQuestEstimate.Context(ranked: true, playerClass: "rogue")

        init() {
            let violet = Card(); violet.id = "EVENT_LOG_VIOLET"; violet.set = .escapefrom_violet_hold
            let other = Card(); other.id = "EVENT_LOG_OTHER"
            Cards.cardsById[violet.id] = violet; Cards.cardsById[other.id] = other
            estimate.beginMatch("event", eligible: true)
            estimate.bind(.init(capturedAt: Date(), quests: AccountQuestEstimate.eventRules.map {
                .init(id: $0.id, progress: 0, status: 2)
            }, achievements: [], definitions: []), scope: "A")
            let player = Entity(id: 3); player[.player_id] = 1; entities[3] = player
        }

        var context: AccountQuestLogTracker.Context {
            .init(playerID: 1, opponentID: 2, mulliganDone: mulliganDone, battlegrounds: battlegrounds,
                  combat: false, turn: turn, defenderID: 0, entity: { self.entities[$0] }, localTurn: ownTurn,
                  handCount: handCount, maxHandSize: handLimit)
        }

        @discardableResult
        func entity(_ id: Int, type: CardType = .minion, owner: Int = 1, zone: Zone = .play,
                    violet: Bool = true) -> Entity {
            let entity = Entity(id: id); entity[.cardtype] = type.rawValue; entity[.controller] = owner
            entity[.zone] = zone.rawValue; entity.cardId = violet ? "EVENT_LOG_VIOLET" : "EVENT_LOG_OTHER"
            entities[id] = entity
            return entity
        }

        func publish(_ samples: [AccountQuestLogTracker.Sample]) {
            for sample in samples {
                switch sample {
                case .action(let event, let id):
                    estimate.observe(event, eventID: id, matchID: "event", isLocalPlayer: true, context: bonus)
                case .cumulative(let metric, let total):
                    estimate.observe(metric, total: total, matchID: "event", isLocalPlayer: true, context: bonus)
                }
            }
        }

        func change(_ tag: GameTag, _ id: Int, _ value: Int, block: Block? = nil, creation: Bool = false) {
            let entity = entities[id]!
            let previous = entity[tag]; entity[tag] = value
            publish(tracker.tagChanged(tag, entity: entity, value: value, previous: previous,
                block: block, context: context, isCreationTag: creation))
        }

        @discardableResult
        func block(_ id: Int, source: Int, type: String = "POWER", parent: Block? = nil) -> Block {
            let block = Block(parent: parent, id: id, type: type, cardId: nil, target: nil, trigger: nil)
            block.sourceEntityId = source
            publish(tracker.blockStarted(block, context: context))
            return block
        }

        func delta(_ id: Int) -> Int? {
            let quota = AccountQuestEstimate.eventRules.first { $0.id == id }!.quota
            return estimate.progress(for: .init(id: id, progress: 0, status: 2), quota: quota, rewardTrack: 7)?.delta
        }
    }

    override func tearDown() {
        Cards.cardsById.removeValue(forKey: "EVENT_LOG_VIOLET")
        Cards.cardsById.removeValue(forKey: "EVENT_LOG_OTHER")
        super.tearDown()
    }

    func testDrawsPairCardAndCounterInEitherOrderAndRejectMillOrMulligan() {
        let h = Harness()
        h.entity(10, type: .spell)
        let block = h.block(1, source: 10)
        h.entity(11, zone: .deck)
        h.change(.num_cards_drawn_this_turn, 3, 1, block: block)
        XCTAssertEqual(h.delta(1987), 2) // Base is immediate, even before the card reveal.
        h.change(.zone, 11, Zone.hand.rawValue, block: block)
        XCTAssertEqual(h.delta(1987), 3)
        h.entity(12, zone: .deck, violet: false)
        h.change(.zone, 12, Zone.hand.rawValue, block: block)
        h.change(.num_cards_drawn_this_turn, 3, 2, block: block)
        XCTAssertEqual(h.delta(1987), 5)
        // Burned/overdrawn cards still have a draw counter; a mill alone does not.
        let burned = h.entity(13, zone: .deck)
        h.publish(h.tracker.burnedCard(burned, block: block, context: h.context))
        h.publish(h.tracker.burnedCard(burned, block: block, context: h.context))
        h.change(.zone, 13, Zone.graveyard.rawValue, block: block)
        h.change(.num_cards_drawn_this_turn, 3, 3, block: block)
        XCTAssertEqual(h.delta(1987), 8)
        h.entity(14, zone: .deck)
        h.change(.zone, 14, Zone.graveyard.rawValue, block: block)
        h.entity(16, zone: .deck, violet: false)
        h.change(.zone, 16, Zone.hand.rawValue, block: block)
        h.change(.num_cards_drawn_this_turn, 3, 4, block: block)
        XCTAssertEqual(h.delta(1987), 10) // Mill + real draw within one block still has no mill bonus.
        h.tracker.blockEnded(block)
        let next = h.block(2, source: 10)
        h.change(.num_cards_drawn_this_turn, 3, 5, block: next)
        h.tracker.blockEnded(next)
        XCTAssertEqual(h.delta(1987), 12) // The old mill cannot lend a bonus to a new draw.
        h.mulliganDone = false
        h.entity(15, zone: .deck)
        h.change(.zone, 15, Zone.hand.rawValue)
        h.change(.num_cards_drawn_this_turn, 3, 6)
        XCTAssertEqual(h.delta(1987), 12)
    }

    func testManaUsesActualPaymentAndSourceInsteadOfPrintedCost() {
        let h = Harness()
        let spell = h.entity(10, type: .spell, zone: .hand); spell[.cost] = 8
        let play = h.block(1, source: 10, type: "PLAY")
        let power = h.block(2, source: 10, parent: play)
        h.change(.num_resources_spent_this_game, 3, 3, block: power)
        XCTAssertEqual(h.delta(1990), 9) // Three actual mana, each base + ranked + expansion.
        h.change(.num_resources_spent_this_game, 3, 2, block: power)
        h.change(.num_resources_spent_this_game, 3, 3, block: power)
        XCTAssertEqual(h.delta(1990), 9)
        h.entity(11, type: .hero_power, violet: false)
        let heroPower = h.block(3, source: 11, type: "PLAY")
        h.change(.num_resources_spent_this_game, 3, 5, block: heroPower)
        XCTAssertEqual(h.delta(1990), 13)
        h.entity(12, type: .spell, zone: .hand)[.cost] = 0
        let freePlay = h.block(4, source: 12, type: "PLAY")
        h.change(.zone, 12, Zone.graveyard.rawValue, block: freePlay)
        XCTAssertEqual(h.delta(1990), 13)
    }

    func testUnmatchedDrawCardCannotCarryIntoAnotherPlayersTurn() {
        let h = Harness()
        h.entity(11, zone: .deck)
        h.change(.zone, 11, Zone.hand.rawValue)
        h.turn = 4; h.ownTurn = false
        h.change(.num_cards_drawn_this_turn, 3, 1)
        XCTAssertEqual(h.delta(1987), 2)
    }

    func testParserRetainsExplicitZeroInsteadOfRestoringPrintedCostOrDeathrattle() {
        let h = Harness()
        let card = Cards.cardsById["EVENT_LOG_VIOLET"]!
        card.cost = 10; card.accountQuestKeywords = ["DEATHRATTLE"]
        let entity = h.entity(10)
        let game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        game.entities[10] = entity
        let parser = TagChangeHandler()
        parser.tagChange(eventHandler: game, tag: .cost, id: 10, value: 0, isCreationTag: true)
        parser.tagChange(eventHandler: game, tag: .deathrattle, id: 10, value: 0, isCreationTag: true)
        XCTAssertEqual(entity.tags[.cost], 0)
        XCTAssertEqual(AccountQuestLogBridge.facts(entity).cost, 0)
        XCTAssertFalse(AccountQuestLogBridge.facts(entity).keywords.contains("DEATHRATTLE"))
    }

    func testStatBuffsCountApplicationsNotPointsOrInitialization() {
        let h = Harness()
        h.entity(10, type: .spell)
        let minion = h.entity(11); minion[.atk] = 2; minion[.health] = 3
        let buff = h.block(1, source: 10)
        h.change(.atk, 11, 5, block: buff)
        h.change(.health, 11, 6, block: buff)
        XCTAssertEqual(h.delta(1988), 2) // +3/+3 is one buff, not six points or two buffs.
        h.change(.atk, 11, 8, block: buff)
        h.change(.health, 11, 9, block: buff)
        XCTAssertEqual(h.delta(1988), 4)
        h.entity(12)
        h.change(.atk, 12, 8, block: buff, creation: true)
        h.change(.health, 12, 9, block: buff, creation: true)
        h.change(.damage, 11, 2, block: buff)
        h.change(.damage, 11, 0, block: buff)
        XCTAssertEqual(h.delta(1988), 4)
        h.tracker.blockEnded(buff)
        let next = h.block(2, source: 10)
        h.change(.health, 11, 10, block: next)
        XCTAssertEqual(h.delta(1988), 6)
        let silence = h.block(3, source: 10)
        h.change(.silenced, 11, 1, block: silence)
        h.change(.atk, 11, 9, block: silence)
        XCTAssertEqual(h.delta(1988), 6)
        h.entity(20, type: .spell, owner: 2)
        h.change(.atk, 11, 10, block: h.block(4, source: 20))
        XCTAssertEqual(h.delta(1988), 6)
    }

    func testFullHandHonorsCapacityAndOnlyCountsOnce() {
        let h = Harness()
        h.entity(10, zone: .deck)
        h.handLimit = 12; h.handCount = 10
        h.change(.zone, 10, Zone.hand.rawValue)
        XCTAssertEqual(h.delta(1992), 0)
        h.handCount = 12
        h.change(.maxhandsize, 3, 12)
        XCTAssertEqual(h.delta(1992), 1)
        h.change(.zone, 10, Zone.graveyard.rawValue)
        h.change(.zone, 10, Zone.hand.rawValue)
        XCTAssertEqual(h.delta(1992), 1)
        h.tracker.reset()
        h.estimate.beginMatch("event", eligible: true)
        h.estimate.bind(.init(capturedAt: Date(), quests: [.init(id: 1992, progress: 0, status: 2)],
            achievements: [], definitions: []), scope: "A")
        h.mulliganDone = false
        h.change(.maxhandsize, 3, 10)
        XCTAssertEqual(h.delta(1992), 0)
    }

    func testDamageTakenSeparatesArmorHealthTurnAndImmunity() {
        let h = Harness()
        let hero = h.entity(10, type: .hero); hero[.health] = 30; hero[.armor] = 3
        h.change(.predamage, 10, 5)
        h.change(.predamage, 10, 0)
        h.tracker.damageStarted(hero, amount: 5, block: nil, context: h.context)
        h.change(.armor, 10, 0)
        h.change(.damage, 10, 2)
        h.change(.predamage, 10, 0)
        XCTAssertEqual(h.delta(1995), 15)
        h.ownTurn = false
        h.change(.predamage, 10, 4)
        h.change(.predamage, 10, 0)
        h.tracker.damageStarted(hero, amount: 4, block: nil, context: h.context)
        h.change(.damage, 10, 6)
        h.change(.predamage, 10, 0)
        XCTAssertEqual(h.delta(1995), 23)
        h.change(.predamage, 10, 5) // Immune: no applied damage.
        h.change(.predamage, 10, 0)
        h.change(.damage, 10, 0) // Heal is not damage.
        h.change(.armor, 10, 10)
        h.change(.armor, 10, 0) // Armor removal without a damage event.
        h.entity(11)[.health] = 5
        h.change(.predamage, 11, 4); h.change(.damage, 11, 4)
        XCTAssertEqual(h.delta(1995), 23)
    }

    func testAttacksUseActualAttackCountAndResetPerTurn() {
        let h = Harness()
        h.entity(10)
        h.block(1, source: 10, type: "ATTACK") // Declaration alone is not a landed attack count.
        XCTAssertEqual(h.delta(1997), 0)
        h.change(.num_attacks_this_turn, 10, 1)
        h.change(.num_attacks_this_turn, 10, 2)
        h.change(.num_attacks_this_turn, 10, 1)
        h.change(.num_attacks_this_turn, 10, 2)
        XCTAssertEqual(h.delta(1997), 8)
        h.turn = 5
        h.change(.num_attacks_this_turn, 10, 0)
        h.change(.num_attacks_this_turn, 10, 1)
        XCTAssertEqual(h.delta(1997), 12)
        h.entity(20, owner: 2)
        h.change(.num_attacks_this_turn, 20, 1)
        XCTAssertEqual(h.delta(1997), 12)
    }

    private struct Choice: IHsCompletedChoice {
        var id: Int
        var choiceType: ChoiceType = .general
        var sourceEntityId = 10
        var offeredEntityIds: [Int]? = [11, 12, 13]
        var chosenEntityIds: [Int]?
    }

    func testDiscoverUsesCompletedSelectionNotOfferedOptionsOrChooseOne() {
        let h = Harness()
        h.entity(10, type: .spell)
        for id in 11...13 { h.entity(id)[.was_discover_option] = 1 }
        let choice = Choice(id: 1, chosenEntityIds: [11, 11])
        h.publish(h.tracker.choiceCompleted(choice, context: h.context))
        h.publish(h.tracker.choiceCompleted(choice, context: h.context))
        XCTAssertEqual(h.delta(1999), 3)
        h.publish(h.tracker.choiceCompleted(Choice(id: 2, chosenEntityIds: []), context: h.context))
        h.publish(h.tracker.choiceCompleted(Choice(id: 3, choiceType: .mulligan, chosenEntityIds: [11]), context: h.context))
        h.entities[12]?[.was_discover_option] = 0
        h.publish(h.tracker.choiceCompleted(Choice(id: 4, chosenEntityIds: [12]), context: h.context))
        XCTAssertEqual(h.delta(1999), 3)
        h.entity(14, type: .spell, violet: false)[.was_discover_option] = 1
        h.publish(h.tracker.choiceCompleted(Choice(id: 5, offeredEntityIds: [13, 14], chosenEntityIds: [13, 14]), context: h.context))
        XCTAssertEqual(h.delta(1999), 8)
    }

    func testMatchResultBrawlWinBonusAndUnknownOrBattlegroundsResults() {
        let h = Harness()
        XCTAssertTrue(h.tracker.matchEnded(result: .unknown, context: h.context).isEmpty)
        h.bonus = AccountQuestLogBridge.context(gameType: .gt_tavernbrawl, playerClass: .rogue)
        h.publish(h.tracker.matchEnded(result: .win, context: h.context))
        h.publish(h.tracker.matchEnded(result: .win, context: h.context))
        XCTAssertEqual(h.delta(1957), 5)
        h.battlegrounds = true
        XCTAssertTrue(h.tracker.matchEnded(result: .win, context: h.context).isEmpty)
        for type in [GameType.gt_tavernbrawl, .gt_tb_1p_vs_ai, .gt_tb_2p_coop, .gt_fsg_brawl_vs_friend] {
            XCTAssertTrue(AccountQuestLogBridge.context(gameType: type, playerClass: nil).tavernBrawl)
        }
        XCTAssertFalse(AccountQuestLogBridge.context(gameType: .gt_ranked, playerClass: nil).tavernBrawl)
    }
}
