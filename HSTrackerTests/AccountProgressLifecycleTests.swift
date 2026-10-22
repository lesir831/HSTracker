import Combine
import XCTest
import SwiftUI
@testable import HSTracker

@MainActor
final class AccountProgressLifecycleTests: XCTestCase {
    private final class Source {
        let lock = NSLock()
        var result: Result<(scope: String, reading: AccountProgressReading), Error>
        init(_ result: Result<(scope: String, reading: AccountProgressReading), Error>) { self.result = result }
        func read(_ full: Bool) throws -> (scope: String, reading: AccountProgressReading) {
            lock.lock(); defer { lock.unlock() }
            return try result.get()
        }
        func set(_ value: Result<(scope: String, reading: AccountProgressReading), Error>) {
            lock.lock(); defer { lock.unlock() }
            result = value
        }
    }

    private let quest = AccountProgressRecord(id: 1035, progress: 176, status: 2)

    func testCompletedEventGameRemainsAnEstimateUntilPostMatchSnapshot() async throws {
        let definitions = Dictionary(uniqueKeysWithValues: try CurrentEventQuestFixtures.load().map { ($0.id, $0) })
        let source = Source(metadataReading(quests: [.init(id: 1957, progress: 10, status: 2)]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: definitions, reader: source.read)
        model.beginMatch("event-result", spectator: false, questEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        let tracker = AccountQuestLogTracker()
        let context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: true,
            battlegrounds: false, combat: false, turn: 10, defenderID: 0, entity: { _ in nil })
        for sample in tracker.matchEnded(result: .win, context: context) {
            if case .action(let event, let id) = sample {
                model.observeQuest(event, eventID: id, matchID: "event-result", context: .init(tavernBrawl: true))
            }
        }
        model.endMatch(preservingCompletedEvent: true)
        overlay.update()
        XCTAssertNil(model.questEstimate.matchID)
        XCTAssertEqual(overlay.rows.first?.total, 15)
        XCTAssertEqual(overlay.rows.first?.confirmed, 10)
        XCTAssertEqual(overlay.rows.first?.estimatedDelta, 5)
        XCTAssertEqual(model.session.snapshot?.quests.first?.progress, 10)
        // A corrected server result replaces the provisional number, even when lower.
        source.set(metadataReading(quests: [.init(id: 1957, progress: 14, status: 2)]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.first?.total, 14)
        XCTAssertNil(overlay.rows.first?.estimatedDelta)
        model.beginMatch("next-event-result", spectator: false, questEligible: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.first?.total, 14)
        XCTAssertEqual(overlay.rows.first?.estimatedDelta, 0)
    }

    func testCurrentEventLogBridgePublishesBonusesAndSettlesWithoutDoubleCounting() async throws {
        let definitions = Dictionary(uniqueKeysWithValues: try CurrentEventQuestFixtures.load().map { ($0.id, $0) })
        let quests = [AccountProgressRecord(id: 1956, progress: 10, status: 2), .init(id: 1986, progress: 5, status: 2)]
        let native = try quests.map { quest -> AccountNativeQuestDefinition in
            let item = try XCTUnwrap(definitions[quest.id])
            return .init(id: item.id, name: item.name, description: item.description, quota: item.quota,
                rewardTrackType: 7, questPoolID: item.id == 1956 ? 143 : 142, poolType: 3, isChainQuest: item.id == 1956)
        }
        let source = Source(metadataReading(quests: quests, definitions: native))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: definitions, reader: source.read)
        model.beginMatch("current-event", spectator: false, questEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        let tracker = AccountQuestLogTracker()
        let spellCard = Card(); spellCard.id = "EVENT_TEST_SHADOW"; spellCard.type = .spell; spellCard.spellSchool = .shadow
        spellCard.playerClass = .priest // A stolen spell must not change the player's class bonus.
        let minionCard = Card(); minionCard.id = "EVENT_TEST_DEATHRATTLE"; minionCard.type = .minion
        minionCard.accountQuestKeywords = ["DEATHRATTLE"]
        for card in [spellCard, minionCard] { Cards.cardsById[card.id] = card }
        defer { for card in [spellCard, minionCard] { Cards.cardsById.removeValue(forKey: card.id) } }
        let spell = Entity(id: 10); spell.cardId = spellCard.id
        spell[.cardtype] = CardType.spell.rawValue; spell[.controller] = 1; spell[.zone] = Zone.hand.rawValue
        let minion = Entity(id: 11); minion.cardId = minionCard.id
        minion[.cardtype] = CardType.minion.rawValue; minion[.controller] = 1; minion[.zone] = Zone.setaside.rawValue
        let entities = [10: spell, 11: minion]
        let context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: true,
            battlegrounds: false, combat: false, turn: 3, defenderID: 0, entity: { entities[$0] })
        let bonus = AccountQuestLogBridge.context(gameType: .gt_ranked, playerClass: .warlock)
        func publish(_ samples: [AccountQuestLogTracker.Sample]) {
            for sample in samples {
                switch sample {
                case .action(let event, let id): model.observeQuest(event, eventID: id, matchID: "current-event", context: bonus)
                case .cumulative(let metric, let total):
                    model.observeQuest(metric, total: total, matchID: "current-event", isLocalPlayer: true, context: bonus)
                }
            }
        }
        let play = Block(parent: nil, id: 1, type: "PLAY", cardId: spellCard.id, target: nil, trigger: nil)
        play.sourceEntityId = spell.id
        publish(tracker.blockStarted(play, context: context))
        spell[.zone] = Zone.play.rawValue
        let spellSamples = tracker.tagChanged(.zone, entity: spell, value: Zone.play.rawValue,
            previous: Zone.hand.rawValue, block: play, context: context)
        publish(spellSamples); publish(spellSamples)
        minion[.zone] = Zone.play.rawValue
        let summoned = tracker.tagChanged(.zone, entity: minion, value: Zone.play.rawValue,
            previous: Zone.setaside.rawValue, block: play, context: context)
        publish(summoned); publish(summoned)
        // Enemy summons and spells cannot advance either task.
        minion[.controller] = 2
        publish(tracker.tagChanged(.zone, entity: minion, value: Zone.play.rawValue,
            previous: Zone.setaside.rawValue, block: nil, context: context))
        spell[.controller] = 2; spell[.zone] = Zone.hand.rawValue
        let enemyPlay = Block(parent: nil, id: 2, type: "PLAY", cardId: spellCard.id, target: nil, trigger: nil)
        enemyPlay.sourceEntityId = spell.id
        publish(tracker.blockStarted(enemyPlay, context: context))
        publish(tracker.tagChanged(.zone, entity: spell, value: Zone.play.rawValue,
            previous: Zone.hand.rawValue, block: enemyPlay, context: context))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(overlay.rows.map(\.total), [14, 8])
        XCTAssertEqual(overlay.rows.map(\.estimatedDelta), [4, 3])
        XCTAssertEqual(model.session.snapshot?.quests.map(\.progress), [10, 5])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        XCTAssertFalse(overlay.isExpanded) // Incoming event progress never opens the popup.
        source.set(metadataReading(quests: [.init(id: 1956, progress: 14, status: 2), .init(id: 1986, progress: 8, status: 2)], definitions: native))
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(overlay.rows.map(\.total), [14, 8])
        model.endMatch()
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [14, 8])
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })
    }

    func testEventDeathrattleFactsRespectEntityOverridesAndRankedContext() {
        let card = Card(); card.id = "EVENT_FACTS_DEATHRATTLE"; card.type = .minion
        card.accountQuestKeywords = ["DEATHRATTLE"]
        Cards.cardsById[card.id] = card
        defer { Cards.cardsById.removeValue(forKey: card.id) }
        let entity = Entity(id: 10); entity.cardId = card.id
        card.cost = 10
        XCTAssertEqual(AccountQuestLogBridge.facts(entity).cost, 10)
        entity[.cost] = 0
        XCTAssertEqual(AccountQuestLogBridge.facts(entity).cost, 0)
        XCTAssertTrue(AccountQuestLogBridge.facts(entity).keywords.contains("DEATHRATTLE"))
        entity[.deathrattle] = 0
        XCTAssertFalse(AccountQuestLogBridge.facts(entity).keywords.contains("DEATHRATTLE"))
        card.accountQuestKeywords = []
        entity[.deathrattle] = 1
        XCTAssertTrue(AccountQuestLogBridge.facts(entity).keywords.contains("DEATHRATTLE"))
        XCTAssertTrue(AccountQuestLogBridge.context(gameType: .gt_ranked, playerClass: .warlock).ranked)
        for type in [GameType.gt_casual, .gt_arena, .gt_tavernbrawl, .gt_battlegrounds] {
            XCTAssertFalse(AccountQuestLogBridge.context(gameType: type, playerClass: .warlock).ranked)
        }
    }

    func testScreenshotObjectivesReceiveLogEventsAndSettleWithoutDoubleCounting() async throws {
        let quests = [AccountProgressRecord(id: 1834, progress: 8, status: 2),
                      .init(id: 1034, progress: 46, status: 2), .init(id: 1037, progress: 1, status: 2),
                      .init(id: 490, progress: 2, status: 2)]
        let definitions = [AccountQuestDefinition(id: 1834, description: "使用$q张紫罗兰监狱卡牌。\n<i>（筹备牌计为双倍！）</i>", quota: 75, rewardTrackType: 1, schedule: .weekly),
                           .init(id: 1034, description: "对敌方英雄造成$q点伤害。", quota: 200, rewardTrackType: 1, schedule: .weekly),
                           .init(id: 1037, description: "在传统对战的排名对战模式中赢得$q场对战。", quota: 5, rewardTrackType: 1, schedule: .weekly),
                           .init(id: 490, description: "施放$q个火焰或暗影法术。", quota: 12, rewardTrackType: 1, schedule: .daily)]
        let source = Source(metadataReading(quests: quests))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) }), reader: source.read)
        model.beginMatch("screenshot", spectator: false, questEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        let tracker = AccountQuestLogTracker()
        let card = Card()
        card.id = "QUEST_TEST_PREPARE"; card.type = .spell; card.set = .escapefrom_violet_hold
        card.spellSchool = .fire; card.accountQuestKeywords = ["PREPARE"]
        Cards.cardsById[card.id] = card
        defer { Cards.cardsById.removeValue(forKey: card.id) }
        let spell = Entity(id: 10)
        spell.cardId = card.id; spell[.cardtype] = CardType.spell.rawValue; spell[.controller] = 1; spell[.zone] = Zone.hand.rawValue
        let hero = Entity(id: 20)
        hero[.cardtype] = CardType.hero.rawValue; hero[.controller] = 2
        let entities = [10: spell, 20: hero]
        let context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: true,
            battlegrounds: false, combat: false, turn: 3, defenderID: 0, entity: { entities[$0] })
        func publish(_ samples: [AccountQuestLogTracker.Sample]) {
            for sample in samples {
                switch sample {
                case .action(let event, let id): model.observeQuest(event, eventID: id, matchID: "screenshot")
                case .cumulative(let metric, let total): model.observeQuest(metric, total: total, matchID: "screenshot", isLocalPlayer: true)
                }
            }
        }
        let play = Block(parent: nil, id: 1, type: "PLAY", cardId: card.id, target: nil, trigger: nil)
        play.sourceEntityId = spell.id
        publish(tracker.blockStarted(play, context: context))
        spell[.zone] = Zone.play.rawValue
        let played = tracker.tagChanged(.zone, entity: spell, value: Zone.play.rawValue,
                                       previous: Zone.hand.rawValue, block: play, context: context)
        publish(played); publish(played) // A replayed delivery is idempotent.
        let power = Block(parent: play, id: 2, type: "POWER", cardId: card.id, target: nil, trigger: nil)
        power.sourceEntityId = spell.id
        publish(tracker.tagChanged(.predamage, entity: hero, value: 6, previous: 0, block: power, context: context))
        publish(tracker.tagChanged(.predamage, entity: hero, value: 0, previous: 6, block: power, context: context))
        // Real logs clear PREDAMAGE before confirming the hit and applying it.
        var metadata = AccountQuestDamageMetadata()
        XCTAssertNil(metadata.read("META_DATA - Meta=DAMAGE Data=6 InfoCount=1"))
        let damage = try XCTUnwrap(metadata.read("Info[0] = [entityName=Enemy id=20 zone=PLAY zonePos=0 cardId=HERO_01 player=2]"))
        tracker.damageStarted(hero, amount: damage.amount, block: power, context: context)
        publish(tracker.tagChanged(.armor, entity: hero, value: 0, previous: 2, block: power, context: context))
        publish(tracker.tagChanged(.damage, entity: hero, value: 4, previous: 0, block: power, context: context))
        // Exercise the actual Combine publication path without a manual overlay.update().
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(overlay.rows.map(\.total), [10, 52, 1, 3])
        XCTAssertEqual(overlay.rows.map(\.estimatedDelta), [2, 6, nil, 1])
        XCTAssertEqual(model.session.snapshot?.quests.map(\.progress), [8, 46, 1, 2])
        XCTAssertFalse(overlay.rows[0].detail.isEmpty)

        let height = overlay.rows.reduce(AccountQuestOverlayLayout.panelChromeHeight) { $0 + $1.displayHeight }
        let frame = CGRect(x: 0, y: 0, width: AccountQuestOverlayLayout.panelWidth, height: height)
        let view = NSHostingView(rootView: AccountQuestOverlayPanel(rows: overlay.rows,
            status: overlay.status, inMatch: true, needsScroll: false).frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("live-quests.png"))
        window.close()

        source.set(metadataReading(quests: zip(quests, [10, 52, 1, 3]).map { .init(id: $0.id, progress: $1, status: 2) }))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [10, 52, 1, 3])
        model.endMatch()
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [10, 52, 1, 3])
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })
    }

    func testDamageAttributionImmuneSelfDamageFatigueAndRetaliation() {
        let tracker = AccountQuestLogTracker()
        let hero = Entity(id: 20); hero[.cardtype] = CardType.hero.rawValue; hero[.controller] = 2
        let defender = Entity(id: 10); defender[.cardtype] = CardType.minion.rawValue; defender[.controller] = 1
        let entities = [10: defender, 20: hero]
        let context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: true,
            battlegrounds: false, combat: false, turn: 3, defenderID: 10, entity: { entities[$0] })
        func hit(_ block: Block?, landed: Bool) -> Int {
            _ = tracker.tagChanged(.predamage, entity: hero, value: 5, previous: 0, block: block, context: context)
            _ = tracker.tagChanged(.predamage, entity: hero, value: 0, previous: 5, block: block, context: context)
            if landed { tracker.damageStarted(hero, amount: 5, block: block, context: context) }
            let samples = landed ? tracker.tagChanged(.damage, entity: hero, value: 5, previous: 0, block: block, context: context) : []
            return samples.reduce(0) { total, sample in
                if case .action(.add(.enemyHeroDamage, let value), _) = sample { return total + value }
                return total
            }
        }
        let enemySpell = Block(parent: nil, id: 1, type: "POWER", cardId: nil, target: nil, trigger: nil)
        enemySpell.sourceEntityId = hero.id
        XCTAssertEqual(hit(enemySpell, landed: true), 0)
        let attack = Block(parent: nil, id: 2, type: "ATTACK", cardId: nil, target: nil, trigger: nil)
        attack.sourceEntityId = hero.id
        XCTAssertEqual(hit(attack, landed: true), 5)
        let friendlySpell = Block(parent: nil, id: 3, type: "POWER", cardId: nil, target: nil, trigger: nil)
        friendlySpell.sourceEntityId = defender.id
        XCTAssertEqual(hit(friendlySpell, landed: false), 0)
        XCTAssertEqual(hit(friendlySpell, landed: true), 5)
        XCTAssertEqual(hit(nil, landed: true), 0)
        let fatigue = Block(parent: friendlySpell, id: 4, type: "FATIGUE", cardId: nil, target: nil, trigger: nil)
        fatigue.sourceEntityId = defender.id
        XCTAssertEqual(hit(fatigue, landed: true), 0)
        XCTAssertTrue(tracker.tagChanged(.damage, entity: hero, value: 0, previous: 5, block: friendlySpell, context: context).isEmpty)
        XCTAssertTrue(tracker.tagChanged(.armor, entity: hero, value: 0, previous: 10, block: friendlySpell, context: context).isEmpty)
    }

    func testConfirmedHeroDamageIsBoundedAndCannotLeakAcrossBlocksOrInitialization() {
        let tracker = AccountQuestLogTracker()
        let hero = Entity(id: 20); hero[.cardtype] = CardType.hero.rawValue; hero[.controller] = 2
        let spell = Entity(id: 10); spell[.controller] = 1
        let entities = [10: spell, 20: hero]
        let context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: true,
            battlegrounds: false, combat: false, turn: 3, defenderID: 0, entity: { entities[$0] })
        let block = Block(parent: nil, id: 1, type: "POWER", cardId: nil, target: nil, trigger: nil)
        block.sourceEntityId = 10
        func loss(_ tag: GameTag, _ value: Int, _ previous: Int, creation: Bool = false) -> Int {
            tracker.tagChanged(tag, entity: hero, value: value, previous: previous,
                block: block, context: context, isCreationTag: creation).reduce(0) { total, sample in
                if case .action(.add(.enemyHeroDamage, let value), _) = sample { return total + value }
                return total
            }
        }
        tracker.damageStarted(hero, amount: 6, block: block, context: context)
        XCTAssertEqual(loss(.damage, 4, 0, creation: true), 0)
        XCTAssertEqual(loss(.armor, 0, 2), 2)
        XCTAssertEqual(loss(.damage, 4, 0), 4)
        XCTAssertEqual(loss(.damage, 4, 0), 0) // Replayed delivery cannot consume the hit twice.
        XCTAssertEqual(loss(.armor, 0, 10), 0) // Later armor removal is not damage.
        tracker.damageStarted(hero, amount: 5, block: block, context: context)
        tracker.blockEnded(block)
        XCTAssertEqual(loss(.damage, 9, 4), 0)
        tracker.damageStarted(hero, amount: 5, block: block, context: context)
        tracker.reset()
        XCTAssertEqual(loss(.damage, 9, 4), 0)
    }

    func testDrawTagsResetByTurnAndModesRejectPractice() {
        let tracker = AccountQuestLogTracker()
        let player = Entity(id: 3); player[.player_id] = 1
        func sample(_ value: Int, previous: Int, turn: Int, mulligan: Bool = true) -> Int {
            let context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: mulligan,
                battlegrounds: false, combat: false, turn: turn, defenderID: 0, entity: { _ in nil })
            return tracker.tagChanged(.num_cards_drawn_this_turn, entity: player, value: value, previous: previous,
                                      block: nil, context: context).reduce(0) { total, sample in
                if case .action(.add(.cardsDrawn, let value), _) = sample { return total + value }
                return total
            }
        }
        XCTAssertEqual(sample(3, previous: 0, turn: 0, mulligan: false), 0)
        XCTAssertEqual(sample(1, previous: 0, turn: 1), 1)
        XCTAssertEqual(sample(3, previous: 1, turn: 1), 2)
        XCTAssertEqual(sample(2, previous: 3, turn: 1), 0)
        XCTAssertEqual(sample(3, previous: 2, turn: 1), 0)
        XCTAssertEqual(sample(0, previous: 3, turn: 2), 0)
        XCTAssertEqual(sample(1, previous: 0, turn: 2), 1)
        for type in [GameType.gt_unknown, .gt_vs_ai, .gt_tutorial, .gt_test, .gt_mercenaries_pve,
                     .gt_battlegrounds_ai_vs_ai, .gt_battlegrounds_duo_vs_ai] {
            XCTAssertFalse(AccountQuestLogBridge.isEligible(gameType: type))
        }
        for type in [GameType.gt_ranked, .gt_casual, .gt_vs_friend, .gt_arena, .gt_tavernbrawl, .gt_battlegrounds, .gt_battlegrounds_duo] {
            XCTAssertTrue(AccountQuestLogBridge.isEligible(gameType: type))
        }
    }

    func testDeathrattlesTurnsAndBattlegroundsActionSources() {
        let tracker = AccountQuestLogTracker()
        let player = Entity(id: 3); player[.player_id] = 1
        let minion = Entity(id: 10); minion[.cardtype] = CardType.minion.rawValue; minion[.controller] = 1
        minion[.zone] = Zone.play.rawValue
        let shop = Entity(id: 20); shop[.cardtype] = CardType.minion.rawValue; shop[.controller] = 2
        shop[.zone] = Zone.play.rawValue
        let entities = [3: player, 10: minion, 20: shop]
        var context = AccountQuestLogTracker.Context(playerID: 1, opponentID: 2, mulliganDone: true,
            battlegrounds: true, combat: false, turn: 3, defenderID: 0, entity: { entities[$0] })
        func amount(_ samples: [AccountQuestLogTracker.Sample], metric: AccountQuestEstimate.Metric) -> Int {
            samples.reduce(0) { total, sample in
                if case .action(.add(let kind, let value), _) = sample, kind == metric { return total + value }
                return total
            }
        }
        let purchase = Block(parent: nil, id: 1, type: "PLAY", cardId: nil, target: nil, trigger: nil)
        purchase.sourceEntityId = shop.id
        _ = tracker.blockStarted(purchase, context: context)
        shop[.controller] = 1; shop[.zone] = Zone.hand.rawValue
        XCTAssertEqual(amount(tracker.tagChanged(.zone, entity: shop, value: Zone.hand.rawValue,
            previous: Zone.play.rawValue, block: purchase, context: context), metric: .cardsBought), 1)
        XCTAssertEqual(amount(tracker.tagChanged(.zone, entity: shop, value: Zone.hand.rawValue,
            previous: Zone.play.rawValue, block: purchase, context: context), metric: .cardsBought), 0)
        // A friendly minion bouncing into hand is not a purchase.
        XCTAssertEqual(amount(tracker.tagChanged(.zone, entity: minion, value: Zone.hand.rawValue,
            previous: Zone.play.rawValue, block: purchase, context: context), metric: .cardsBought), 0)
        XCTAssertEqual(amount(tracker.tagChanged(.player_tech_level, entity: player, value: 2,
            previous: 1, block: nil, context: context), metric: .tavernUpgrades), 1)
        XCTAssertTrue(tracker.tagChanged(.player_tech_level, entity: player, value: 1,
            previous: 0, block: nil, context: context).isEmpty)
        context = .init(playerID: 1, opponentID: 2, mulliganDone: true, battlegrounds: true,
                        combat: true, turn: 3, defenderID: 0, entity: { entities[$0] })
        minion[.predamage] = 3
        XCTAssertEqual(amount(tracker.tagChanged(.divine_shield, entity: minion, value: 0,
            previous: 1, block: nil, context: context), metric: .divineShields), 1)
        minion[.predamage] = 0
        XCTAssertTrue(tracker.tagChanged(.divine_shield, entity: minion, value: 0,
            previous: 1, block: nil, context: context).isEmpty)
        minion[.health] = 5; minion[.damage] = 5
        XCTAssertEqual(amount(tracker.tagChanged(.zone, entity: minion, value: Zone.graveyard.rawValue,
            previous: Zone.play.rawValue, block: nil, context: context), metric: .minionsDestroyed), 1)
        let deathrattle = Block(parent: nil, id: 5, type: "TRIGGER", cardId: nil, target: nil, trigger: "DEATHRATTLE")
        deathrattle.sourceEntityId = minion.id
        XCTAssertEqual(amount(tracker.blockStarted(deathrattle, context: context), metric: .deathrattles), 1)
        minion[.controller] = 2
        XCTAssertTrue(tracker.blockStarted(deathrattle, context: context).isEmpty)
        context = .init(playerID: 1, opponentID: 2, mulliganDone: true, battlegrounds: false,
                        combat: false, turn: 3, defenderID: 0, entity: { entities[$0] }, localTurn: true)
        XCTAssertEqual(amount(tracker.tagChanged(.step, entity: Entity(id: 1), value: Step.main_start.rawValue,
            previous: Step.main_start_triggers.rawValue, block: nil, context: context), metric: .turnsTaken), 1)
        context.localTurn = false
        XCTAssertTrue(tracker.tagChanged(.step, entity: Entity(id: 1), value: Step.main_start.rawValue,
            previous: Step.main_start_triggers.rawValue, block: nil, context: context).isEmpty)
    }

    func testActualCardDefinitionsAndPowerBlockMetadata() throws {
        let database = Database()
        database.loadDatabase(splashscreen: nil, withLanguages: [.enUS])
        XCTAssertTrue(try XCTUnwrap(Cards.any(byId: "JAIL_321")).accountQuestKeywords.contains("PREPARE"))
        XCTAssertTrue(try XCTUnwrap(Cards.any(byId: "CATA_134")).accountQuestKeywords.contains("SHATTER"))
        XCTAssertTrue(try XCTUnwrap(Cards.any(byId: "EX1_029")).accountQuestKeywords.contains("DEATHRATTLE"))
        // Brann's text references Battlecry; Brann himself has no Battlecry.
        XCTAssertFalse(try XCTUnwrap(Cards.any(byId: "LOE_077")).accountQuestKeywords.contains("BATTLECRY"))
        let game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        let parser = PowerGameStateParser(with: game)
        for (index, type) in ["PLAY", "ATTACK", "TRIGGER"].enumerated() {
            let line = "D 12:00:00.0000000 GameState.DebugPrintPower() - BLOCK_START BlockType=\(type) Entity=[entityName=Test id=10 zone=PLAY zonePos=1 cardId=JAIL_321 player=1] EffectCardId= EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=DEATHRATTLE"
            parser.handle(logLine: LogLine(namespace: .power, line: line))
            XCTAssertEqual(parser.currentBlock?.sourceEntityId, 10, "Block \(index)")
            XCTAssertEqual(parser.currentBlock?.triggerKeyword, "DEATHRATTLE")
        }
    }

    func testEventSettlementChainReplacementAndMetadataRecovery() async throws {
        let catalog = Dictionary(uniqueKeysWithValues: try HistoricalEventQuestFixtures.load().map { ($0.id, $0) })
        func native(_ id: Int, chain: Bool?, pool: Int = 20) throws -> AccountNativeQuestDefinition {
            let item = try XCTUnwrap(catalog[id])
            return AccountNativeQuestDefinition(id: id, name: item.name, description: item.description,
                quota: item.quota, rewardTrackType: 7, questPoolID: pool, poolType: 3, isChainQuest: chain)
        }
        let first = AccountProgressRecord(id: 1890, progress: 100, status: 2)
        let daily = AccountProgressRecord(id: 1904, progress: 3, status: 2)
        let source = Source(metadataReading(quests: [first, daily],
            definitions: [try native(1890, chain: true), try native(1904, chain: false)]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: catalog, showTraditionalQuests: true, showBattlegroundsQuests: false, reader: source.read)
        model.beginMatch("event-game", spectator: false, questEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(overlay.rows.map(\.id), [1890, 1904])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        model.observeQuest(.manaSpent, total: 100, matchID: "event-game", isLocalPlayer: true)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [100, 3])

        // An authoritative settlement already includes every applicable bonus.
        let settled = AccountProgressRecord(id: 1890, progress: 123, status: 2)
        source.set(metadataReading(quests: [settled, daily], definitions: [try native(1890, chain: nil)]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.total), [123, 3])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        XCTAssertNil(model.session.snapshot?.nativeQuestDefinitions.first?.isChainQuest)
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })

        // Explicit false and a changed pool replace retained chain membership.
        source.set(metadataReading(quests: [settled], definitions: [try native(1890, chain: false)]))
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[1890]?.isChainQuest, false)
        source.set(metadataReading(quests: [settled], definitions: [try native(1890, chain: true)]))
        model.refresh(full: true)
        await idle(model)
        source.set(metadataReading(quests: [settled], definitions: [try native(1890, chain: nil, pool: 21)]))
        model.refresh(full: true)
        await idle(model)
        XCTAssertNil(model.questDefinitions[1890]?.isChainQuest)

        // The full catalog does not expose a future chain step before assignment.
        let next = AccountProgressRecord(id: 1891, progress: 4, status: 2)
        source.set(metadataReading(quests: [.init(id: 1890, progress: 500, status: 4), next,
                                          .init(id: 1904, progress: 3, status: 9)],
            definitions: [try native(1891, chain: true)]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [1891])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEventChain")
        // Missing native metadata for a different account cannot borrow chain labels.
        source.set(metadataReading(scope: "B", quests: [next]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEvent")
        XCTAssertEqual(overlay.rows.first?.total, 4)
    }

    func testRenderHistoricalEventObjectivesAndBonuses() async throws {
        let catalog = try HistoricalEventQuestFixtures.load()
        let definitions = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let selected = [1890, 1904, 1923]
        let native = try selected.enumerated().map { index, id -> AccountNativeQuestDefinition in
            let item = try XCTUnwrap(definitions[id])
            return AccountNativeQuestDefinition(id: id, name: item.name, description: item.description,
                quota: item.quota, rewardTrackType: 7, questPoolID: 20 + index,
                poolType: index == 1 ? 1 : 3, isChainQuest: index != 1)
        }
        let source = Source(metadataReading(quests: selected.map { .init(id: $0, progress: 3, status: 2) }, definitions: native))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: definitions, showTraditionalQuests: true, showBattlegroundsQuests: false, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(overlay.rows.count, 3)
        let height = overlay.rows.reduce(AccountQuestOverlayLayout.panelChromeHeight) { $0 + $1.displayHeight }
        let frame = CGRect(x: 0, y: 0, width: AccountQuestOverlayLayout.panelWidth, height: height)
        let view = NSHostingView(rootView: AccountQuestOverlayPanel(rows: overlay.rows,
            status: overlay.status, inMatch: true, needsScroll: false)
            .frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("events.png"))
        window.close()
    }

    func testPlayerTagsDoNotRequireCardControllerTag() {
        let entity = Entity(id: 3)
        entity[.player_id] = 2
        XCTAssertFalse(entity.isControlled(by: 2))
        XCTAssertTrue(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 2))
        XCTAssertFalse(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 1))
        XCTAssertFalse(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 0))
        // An explicit player identity takes priority over a stale controller.
        entity[.controller] = 1
        XCTAssertFalse(AccountQuestLogBridge.isLocalPlayer(entity, playerID: 1))
    }
    private func success(_ scope: String = "A") -> Result<(scope: String, reading: AccountProgressReading), Error> {
        .success((scope, AccountProgressReading(snapshot: AccountProgressSnapshot(capturedAt: Date(),
            quests: [quest], achievements: [], definitions: []), inGame: [:])))
    }

    private func idle(_ model: AccountProgressModel) async {
        let deadline = Date().addingTimeInterval(5)
        while model.refreshing && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.refreshing)
    }

    private func metadataReading(scope: String = "A", quests: [AccountProgressRecord],
                                 definitions: [AccountNativeQuestDefinition] = [])
        -> Result<(scope: String, reading: AccountProgressReading), Error> {
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: quests, achievements: [],
                                               definitions: [], nativeQuestDefinitions: definitions)
        return .success((scope, AccountProgressReading(snapshot: snapshot, inGame: [:])))
    }

    func testDelayedMirrorSceneDoesNotTerminateLogOwnedMatch() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.manaSpent, total: 7, matchID: "game", isLocalPlayer: true)
        model.sceneChanged("friendly") // delayed mirror frame after log gameStart
        await idle(model)
        XCTAssertEqual(model.questEstimate.matchID, "game")
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.total, 183)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_LiveTracking")
    }

    func testTemporaryMissingIdentityRecoversWithoutLosingBaselineOrTags() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        source.set(.failure(AccountProgressReadFailure(scope: nil, reason: "accountUnavailable")))
        model.refresh(full: false)
        await idle(model)
        XCTAssertFalse(model.hasVerifiedAccount)
        model.observeQuest(.manaSpent, total: 7, matchID: "game", isLocalPlayer: true)
        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertTrue(model.hasVerifiedAccount)
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.total, 183)
    }

    func testFirstReadFailureDoesNotAbandonMatchAndZeroEstimateIsVisible() async {
        let source = Source(.failure(AccountProgressReadFailure(scope: nil, reason: "accountUnavailable")))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_WaitingAccount")
        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.delta, 0)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_LiveTracking")
    }

    func testConfirmedAccountSwitchAndGameCloseDiscardEstimates() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.manaSpent, total: 7, matchID: "game", isLocalPlayer: true)
        source.set(success("B"))
        model.refresh(full: true)
        await idle(model)
        XCTAssertNil(model.questEstimate.matchID)
        model.gameClosed()
        XCTAssertNil(model.session.snapshot)
        XCTAssertFalse(model.hasVerifiedAccount)
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_NoActiveMatch")
    }

    func testFirstKnownIdentityFailureKeepsOverlayMatchAlive() async {
        let source = Source(.failure(AccountProgressReadFailure(scope: "A", reason: "questStateNotReady")))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        XCTAssertTrue(model.overlayMatchActive)
        XCTAssertFalse(model.hasVerifiedAccount)
        source.set(success())
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questEstimate.progress(for: quest, quota: 500)?.delta, 0)
        XCTAssertTrue(model.overlayMatchActive)
    }

    func testEnablingDuringMatchShowsAccountProgressWithoutInventingOpeningBaseline() async {
        let source = Source(success())
        let model = AccountProgressModel(enabled: false, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.beginMatch("game", spectator: false, questEligible: true)
        XCTAssertTrue(model.overlayMatchActive)
        // Automatic polling/definition downloads are disabled for this fixture.
        model.setOverlayEnabled(true)
        await idle(model)
        XCTAssertTrue(model.overlayEnabled)
        XCTAssertTrue(model.overlayMatchActive)
        XCTAssertNil(model.questEstimate.progress(for: quest, quota: 500))
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_JoinedMidMatch")
        model.endMatch()
        XCTAssertFalse(model.overlayMatchActive)
    }

    func testBattlegroundsCanDisplayQuestsWithoutTraditionalGameEstimates() async {
        let model = makeOverlayModel()
        model.beginMatch("battlegrounds", spectator: false, questEligible: false, overlayEligible: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertTrue(overlay.isShown)
        XCTAssertFalse(overlay.rows.isEmpty)
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })
        XCTAssertEqual(model.questTrackingStatus, "AccountProgress_MatchNotEstimated")
        model.beginMatch("spectating-battlegrounds", spectator: true, questEligible: false, overlayEligible: true)
        await idle(model)
        overlay.update()
        XCTAssertFalse(overlay.isShown)
    }

    func testNativeQuestMetadataOverridesFallbackAndTracksSnapshotReplacement() async {
        let native = AccountNativeQuestDefinition(id: 1035, name: "Mana quest", description: "Spend $q mana.",
            quota: 500, rewardTrackType: 1, questPoolID: 2, poolType: 2)
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: [quest], achievements: [],
            definitions: [], nativeQuestDefinitions: [native])
        let source = Source(.success(("fixture", AccountProgressReading(snapshot: snapshot, inGame: [:]))))
        let fallback = AccountQuestDefinition(id: 1035, description: "Old description", quota: 999, rewardTrackType: 2)
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            definitions: [1035: fallback], showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[1035]?.quota, 500)
        XCTAssertEqual(model.questDefinitions[1035]?.schedule, .weekly)
        XCTAssertEqual(model.questDefinitions[1035]?.rewardTrackType, 1)
        XCTAssertEqual(model.questDefinitions[1035]?.text, "Spend 500 mana.")
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(overlay.rows.map(\.id), [1035])

        // A reroll/claim replaces the server list; stale rows and their native
        // metadata must not survive a later authoritative snapshot.
        let replacement = AccountProgressSnapshot(capturedAt: Date(),
            quests: [AccountProgressRecord(id: 2000, progress: 4, status: 2)], achievements: [], definitions: [],
            nativeQuestDefinitions: [AccountNativeQuestDefinition(id: 2000, name: "", description: "Draw $q cards.",
                quota: 30, rewardTrackType: 2, questPoolID: 8, poolType: 1)])
        source.set(.success(("fixture", AccountProgressReading(snapshot: replacement, inGame: [:]))))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [2000])
        XCTAssertEqual(model.questDefinitions[2000]?.schedule, .daily)
        XCTAssertEqual(model.questDefinitions[1035], fallback)
    }

    func testNativeMetadataSurvivesMissingAndPartialReadsOnlyWhileTasksRemainAssigned() async {
        let quests = [AccountProgressRecord(id: 3001, progress: 2, status: 2),
                      AccountProgressRecord(id: 3002, progress: 3, status: 2)]
        let native = [AccountNativeQuestDefinition(id: 3001, name: "", description: "Event task $q", quota: 10,
                                                  rewardTrackType: 7, questPoolID: 1, poolType: 1),
                      AccountNativeQuestDefinition(id: 3002, name: "", description: "Other weekly $q", quota: 20,
                                                  rewardTrackType: 9, questPoolID: 2, poolType: 2)]
        let fallback = [3001: AccountQuestDefinition(id: 3001, description: "Old event", quota: 999, rewardTrackType: 7),
                        3002: AccountQuestDefinition(id: 3002, description: "Old other", quota: 999, rewardTrackType: 9)]
        let source = Source(metadataReading(quests: quests, definitions: native))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                         definitions: fallback, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(overlay.rows.map(\.id), [3001, 3002])

        let advanced = [AccountProgressRecord(id: 3001, progress: 4, status: 2),
                        AccountProgressRecord(id: 3002, progress: 5, status: 2)]
        source.set(metadataReading(quests: advanced))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [3001, 3002])
        XCTAssertEqual(overlay.rows.map(\.schedule), [.daily, .weekly])
        XCTAssertEqual(overlay.rows.map(\.quota), [10, 20])
        XCTAssertEqual(overlay.rows.map(\.confirmed), [4, 5])
        XCTAssertTrue(overlay.rows.allSatisfy { $0.estimatedDelta == nil })
        // The display cache must not rewrite the authoritative snapshot saved to disk.
        XCTAssertEqual(model.session.snapshot?.quests, advanced)
        XCTAssertEqual(model.session.snapshot?.nativeQuestDefinitions.count, 0)

        let changedNative = AccountNativeQuestDefinition(id: 3001, name: "", description: "Updated $q", quota: 25,
                                                         rewardTrackType: 7, questPoolID: 2, poolType: 2)
        source.set(metadataReading(quests: advanced, definitions: [changedNative]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.schedule), [.weekly, .weekly])
        XCTAssertEqual(overlay.rows.map(\.quota), [25, 20])
        XCTAssertEqual(overlay.rows.first?.title, "Updated 25")

        source.set(metadataReading(quests: [advanced[0]]))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [3001])
        XCTAssertEqual(model.questDefinitions[3002], fallback[3002])

        // A removed task that later reappears needs new native confirmation.
        source.set(metadataReading(quests: advanced))
        model.refresh(full: true)
        await idle(model)
        overlay.update()
        XCTAssertEqual(overlay.rows.map(\.id), [3001])
        XCTAssertEqual(model.questDefinitions[3002]?.schedule, .unknown)
    }

    func testNativeMetadataRetainsMissingCadenceOnlyForUnchangedQuestPool() async {
        let quest = AccountProgressRecord(id: 3030, progress: 2, status: 2)
        func native(pool: Int, period: Int?, quota: Int) -> AccountNativeQuestDefinition {
            AccountNativeQuestDefinition(id: quest.id, name: "", description: "Updated task $q", quota: quota,
                                         rewardTrackType: 7, questPoolID: pool, poolType: period)
        }
        let source = Source(metadataReading(quests: [quest], definitions: [native(pool: 10, period: 1, quota: 10)]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, .daily)

        let cases: [(pool: Int, period: Int?, quota: Int, schedule: AccountQuestSchedule)] = [
            (10, nil, 12, .daily), // A missing join retains its previously verified cadence.
            (10, 0, 13, .unknown), // Explicit NONE must replace the old daily value.
            (10, 2, 14, .weekly),
            (10, 99, 15, .unknown), // Future enum values are explicit, not missing.
            (10, 2, 16, .weekly),
            (11, nil, 17, .unknown) // A changed pool cannot inherit the previous pool's cadence.
        ]
        for item in cases {
            source.set(metadataReading(quests: [quest],
                definitions: [native(pool: item.pool, period: item.period, quota: item.quota)]))
            model.refresh(full: true)
            await idle(model)
            overlay.update()
            XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, item.schedule)
            XCTAssertEqual(model.questDefinitions[quest.id]?.quota, item.quota)
            XCTAssertEqual(model.questDefinitions[quest.id]?.text, "Updated task \(item.quota)")
            XCTAssertEqual(overlay.rows.map(\.id), [quest.id])
            XCTAssertEqual(model.session.snapshot?.nativeQuestDefinitions.first?.poolType, item.period)
        }
    }

    func testNativeMetadataDoesNotCrossSuccessfulOrFailedAccountSwitch() async {
        let quest = AccountProgressRecord(id: 3010, progress: 2, status: 2)
        let native = AccountNativeQuestDefinition(id: quest.id, name: "", description: "Event task $q", quota: 10,
                                                  rewardTrackType: 7, questPoolID: 1, poolType: 1)
        let fallback = AccountQuestDefinition(id: quest.id, description: "Unclassified event", quota: 10, rewardTrackType: 7)
        for failsFirst in [false, true] {
            let source = Source(metadataReading(quests: [quest], definitions: [native]))
            let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                             definitions: [quest.id: fallback], showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
            model.refresh(full: true)
            await idle(model)
            XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, .daily)

            if failsFirst {
                source.set(.failure(AccountProgressReadFailure(scope: "B", reason: "questStateNotReady")))
                model.refresh(full: true)
                await idle(model)
                XCTAssertFalse(model.hasVerifiedAccount)
                XCTAssertEqual(model.questDefinitions[quest.id], fallback)
            }
            source.set(metadataReading(scope: "B", quests: [quest]))
            model.refresh(full: true)
            await idle(model)
            XCTAssertEqual(model.questDefinitions[quest.id], fallback)
            let overlay = AccountQuestOverlayViewModel(model: model)
            XCTAssertEqual(overlay.rows.map(\.id), [quest.id])
            XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEvent")
        }
    }

    func testClosingGameClearsNativeMetadataBeforeSameAccountReopens() async {
        let quest = AccountProgressRecord(id: 3020, progress: 2, status: 2)
        let native = AccountNativeQuestDefinition(id: quest.id, name: "", description: "Event task $q", quota: 10,
                                                  rewardTrackType: 7, questPoolID: 1, poolType: 1)
        let fallback = AccountQuestDefinition(id: quest.id, description: "Unclassified event", quota: 10, rewardTrackType: 7)
        let source = Source(metadataReading(quests: [quest], definitions: [native]))
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
                                         definitions: [quest.id: fallback], showTraditionalQuests: true, showBattlegroundsQuests: true, reader: source.read)
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[quest.id]?.schedule, .daily)

        model.gameClosed()
        XCTAssertNil(model.session.snapshot)
        XCTAssertEqual(model.questDefinitions[quest.id], fallback)
        source.set(metadataReading(quests: [quest]))
        model.refresh(full: true)
        await idle(model)
        XCTAssertEqual(model.questDefinitions[quest.id], fallback)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(overlay.rows.map(\.id), [quest.id])
        XCTAssertEqual(overlay.rows.first?.categoryKey, "AccountProgress_CategoryEvent")
    }

    func testQuestListOnlyTogglesOnClickWhileProgressContinuesUpdating() async throws {
        let model = makeOverlayModel()
        let overlay = AccountQuestOverlayViewModel(model: model)
        overlay.toggleExpanded()
        XCTAssertFalse(overlay.isExpanded)
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        XCTAssertFalse(model.panelVisible)
        XCTAssertTrue(overlay.isShown)
        XCTAssertEqual(overlay.rows.first?.estimatedDelta, 0)
        XCTAssertFalse(overlay.isExpanded)
        model.observeQuest(.heroPowerUses, total: 1, matchID: "game", isLocalPlayer: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(overlay.rows.first?.total, 10)
        XCTAssertFalse(overlay.isExpanded)

        overlay.toggleExpanded()
        XCTAssertTrue(overlay.isExpanded)
        model.observeQuest(.heroPowerUses, total: 2, matchID: "game", isLocalPlayer: true)
        // Wait beyond the former five-second reveal timeout. Opening the list
        // must not stop updates, dismiss it, or open the diagnostic window.
        try await Task.sleep(nanoseconds: 5_300_000_000)
        XCTAssertEqual(overlay.rows.first?.total, 11)
        XCTAssertTrue(overlay.isExpanded)
        XCTAssertFalse(model.panelVisible)
        overlay.toggleExpanded()
        XCTAssertFalse(overlay.isExpanded)
        model.observeQuest(.heroPowerUses, total: 3, matchID: "game", isLocalPlayer: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(overlay.rows.first?.total, 12)
        XCTAssertFalse(overlay.isExpanded)

        overlay.toggleExpanded()
        model.endMatch()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(overlay.isShown)
        XCTAssertFalse(overlay.isExpanded)
        model.beginMatch("spectating", spectator: true, questEligible: true)
        await idle(model)
        overlay.update()
        XCTAssertFalse(overlay.isShown)
    }

    func testRootOverlayLoadsAsNonactivatingPanelBeforeBeingShown() throws {
        let controller = RootOverlayWindow(windowNibName: "RootOverlayWindow")
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        defer { panel.close() }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(controller.alwaysLocked)
    }

    private func makeOverlayModel() -> AccountProgressModel {
        let quests = [AccountProgressRecord(id: 1032, progress: 9, status: 2),
                      AccountProgressRecord(id: 443, progress: 0, status: 2), quest]
        let definitions = [AccountQuestDefinition(id: 1032, description: "使用$q次英雄技能。", quota: 20, rewardTrackType: 1),
                           AccountQuestDefinition(id: 443, description: "使用死亡骑士、恶魔猎手或圣骑士完成$q场对战。", quota: 3, rewardTrackType: 1),
                           AccountQuestDefinition(id: 1035, description: "消耗$q点法力值。", quota: 500, rewardTrackType: 1)]
        let native = definitions.map {
            AccountNativeQuestDefinition(id: $0.id, name: "", description: $0.description, quota: $0.quota,
                rewardTrackType: $0.rewardTrackType, questPoolID: $0.id == 443 ? 1 : 2,
                poolType: $0.id == 443 ? 1 : 2)
        }
        let snapshot = AccountProgressSnapshot(capturedAt: Date(), quests: quests, achievements: [], definitions: [],
                                               nativeQuestDefinitions: native)
        return AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            overlayEnabled: true,
            definitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) }),
            showTraditionalQuests: true, showBattlegroundsQuests: true, reader: { _ in ("fixture", AccountProgressReading(snapshot: snapshot, inGame: [:])) })
    }

    /// Renders the actual production view with deterministic sample data for
    /// visual review. This is not a claim of fresh-game end-to-end acceptance.
    func testRenderQuestOverlayUsingBundledHearthstoneAssets() async throws {
        for name in ["xp_scroll_item", "xp_gem", "hs_banner", "flavor_text", "xp_empty_bar", "xp_filled_bar"] {
            XCTAssertNotNil(NSImage(named: name), "Missing bundled artwork: \(name)")
        }
        let model = makeOverlayModel()
        model.beginMatch("game", spectator: false, questEligible: true)
        await idle(model)
        model.observeQuest(.heroPowerUses, total: 1, matchID: "game", isLocalPlayer: true)
        model.observeQuest(.manaSpent, total: 15, matchID: "game", isLocalPlayer: true)
        let overlay = AccountQuestOverlayViewModel(model: model)
        overlay.toggleExpanded()
        XCTAssertTrue(overlay.isExpanded)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let view = NSHostingView(rootView: AccountQuestOverlayView(viewModel: overlay,
            placement: overlay.placement, canvasWidth: frame.width, canvasSize: frame.size, isLocked: true)
            .background(Color(red: 0.13, green: 0.17, blue: 0.17)))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("expanded.png"))
        let header = AccountQuestOverlayLayout.headerFrame(canvasWidth: frame.width,
            horizontal: overlay.placement.horizontal, vertical: overlay.placement.vertical)
        let panel = AccountQuestOverlayLayout.panelFrame(header: header, rowCount: overlay.rows.count)
        let detailRect = header.union(panel).insetBy(dx: -8, dy: -8).intersection(view.bounds)
        let detail = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: detailRect))
        view.cacheDisplay(in: detailRect, to: detail)
        try XCTUnwrap(detail.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("detail.png"))
        window.close()
    }

    func testRenderMenuQuestsAboveExistingExperienceBar() async throws {
        let model = makeOverlayModel()
        model.setMenuActive(true)
        model.refresh(full: true)
        await idle(model)
        let experience = ExperienceCounterViewModel()
        experience.isShown = true
        experience.xpDisplay = "385/1325"
        experience.levelDisplay = "102"
        experience.percentage = 385.0 / 1325
        let overlay = AccountQuestOverlayViewModel(model: model, experience: experience)
        overlay.toggleMenu()
        await idle(model)
        XCTAssertTrue(overlay.menuExpanded)
        XCTAssertFalse(overlay.isShown)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let view = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            AccountQuestExperienceEntryView(quests: overlay, experience: experience,
                                           canvasWidth: frame.width, canvasScale: 1)
            AccountQuestMenuOverlayView(viewModel: overlay, canvasWidth: frame.width, canvasSize: frame.size)
        }.background(Color(red: 0.13, green: 0.17, blue: 0.17)))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let entry = ExperienceCounterView.visualFrame(canvasWidth: frame.width)
        let panel = AccountQuestOverlayLayout.panelFrame(header: entry, rowCount: overlay.rows.count)
        XCTAssertLessThan(panel.maxY, entry.minY)
        let detailRect = entry.union(panel).insetBy(dx: -8, dy: -8).intersection(view.bounds)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: detailRect))
        view.cacheDisplay(in: detailRect, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("menu.png"))
        window.close()
    }

    func testRenderLongRecurringObjectivesWithoutTruncation() async throws {
        let descriptions = [
            "在卡牌对战各模式中召唤$q个随从。完成指定职业、指定版本卡牌和指定模式的额外条件时，以游戏确认的任务进度为准。",
            "抽$q张牌。", "消灭$q个随从。", "赢得$q场酒馆战棋对局。",
            "使用圣骑士完成$q场对战。", "使用$q张法术牌。", "进行$q个回合。"
        ]
        let native = descriptions.enumerated().map { index, description in
            AccountNativeQuestDefinition(id: 25000 + index, name: "", description: description,
                quota: index == 3 ? 3 : 30, rewardTrackType: index == 3 ? 2 : 1,
                questPoolID: index.isMultiple(of: 2) ? 1 : 2, poolType: index.isMultiple(of: 2) ? 1 : 2)
        }
        let snapshot = AccountProgressSnapshot(capturedAt: Date(),
            quests: native.map { AccountProgressRecord(id: $0.id, progress: 1, status: 2) },
            achievements: [], definitions: [], nativeQuestDefinitions: native)
        let model = AccountProgressModel(enabled: true, automaticallyPoll: false, persists: false,
            overlayEnabled: true, showTraditionalQuests: true, showBattlegroundsQuests: true, reader: { _ in ("fixture", AccountProgressReading(snapshot: snapshot, inGame: [:])) })
        model.refresh(full: true)
        await idle(model)
        let overlay = AccountQuestOverlayViewModel(model: model)
        XCTAssertEqual(overlay.rows.count, 7)
        XCTAssertGreaterThan(overlay.rows[0].displayHeight, AccountQuestOverlayLayout.rowHeight)
        let frame = CGRect(x: 0, y: 0, width: AccountQuestOverlayLayout.panelWidth, height: 650)
        let view = NSHostingView(rootView: AccountQuestOverlayPanel(rows: overlay.rows,
            status: overlay.status, inMatch: false, needsScroll: true)
            .frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/tmp/HSTracker-QuestOverlay-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("recurring-long.png"))
        window.close()
    }
}
