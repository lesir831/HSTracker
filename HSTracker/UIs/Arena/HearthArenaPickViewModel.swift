import Combine
import Foundation

struct HearthArenaPickRating: Identifiable, Equatable {
    let id: Int // Offered slot, not card ID: duplicate offers stay independent.
    let cardID: String
    let score: Double?
    let isPackage: Bool

    var scoreText: String {
        guard let score else { return "—" }
        return score == score.rounded() ? String(Int(score)) : String(score)
    }
}

/// Independent of Arenasmith's subscription gates, scores and upload metadata.
/// Watcher events and published state are delivered on the main queue.
final class HearthArenaPickViewModel: ObservableObject {
    typealias Loader = () async throws -> HearthArenaRatingsResult
    @Published private(set) var rows: [HearthArenaPickRating] = []
    @Published private(set) var enabled: Bool
    @Published private(set) var statusKey = "HearthArena_Loading"
    @Published private(set) var isDrafting = false
    @Published private(set) var isAnimating = false
    @Published private(set) var isHeroZoomed = false
    @Published private(set) var isPackageSelectOpen = false
    @Published private(set) var fetchedAt: Date?

    private let loader: Loader
    private let lookup: (String) -> (type: CardType, cardClass: CardClass)?
    private var hero = ""
    private var heroPower = ""
    private var offers: [ArenaDraftChoice] = []
    private var generation = 0
    private var task: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?

    var isVisible: Bool {
        enabled && isDrafting && !isAnimating && !isHeroZoomed && !isPackageSelectOpen && !rows.isEmpty
    }

    init(watcher: ArenaStateWatcher? = Watchers.arenaStateWatcher, enabled: Bool? = nil,
         loader: @escaping Loader = { try await HearthArenaRatingsService.shared.ratings() },
         lookup: @escaping (String) -> (type: CardType, cardClass: CardClass)? = {
             Cards.any(byId: $0).map { ($0.type, $0.playerClass) }
         }) {
        self.enabled = enabled ?? Settings.showHearthArenaScores
        self.loader = loader
        self.lookup = lookup
        watcher?.onClientStateChanged.subscribe { [weak self] in self?.setClientState($0) }
        watcher?.onChoicesChanged.subscribe { [weak self] in self?.setChoices($0) }
        watcher?.onHeroPicked.subscribe { [weak self] in self?.setHero($0) }
        watcher?.onHeroPowerPicked.subscribe { [weak self] in self?.setHeroPower($0) }
        watcher?.onIsAnimatingChanged.subscribe { [weak self] in self?.isAnimating = $0 }
        watcher?.onHeroZoomed.subscribe { [weak self] in self?.isHeroZoomed = $0 != nil }
        watcher?.onIsPackageSelectOpen.subscribe { [weak self] in self?.isPackageSelectOpen = $0 }
        watcher?.onDeckIdChanged.subscribe { [weak self] _ in self?.setChoices([]) }
        settingsSubscription = NotificationCenter.default.publisher(for: Notification.Name(Settings.show_heartharena_scores))
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.setEnabled(Settings.showHearthArenaScores) }
    }

    deinit { task?.cancel() }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reload()
    }

    func setClientState(_ state: ArenaClientState) {
        isDrafting = state.clientState.isDrafting
            && state.sessionState != .editing_deck
        if !isDrafting { offers = [] }
        reload()
    }

    func setHero(_ id: String) { hero = id; reload() }
    func setHeroPower(_ id: String) { heroPower = id; reload() }
    func setChoices(_ choices: [ArenaDraftChoice]) { offers = choices; reload() }

    func reset() {
        hero = ""
        heroPower = ""
        offers = []
        isDrafting = false
        isAnimating = false
        isHeroZoomed = false
        isPackageSelectOpen = false
        reload()
    }

    private func reload() {
        generation += 1
        task?.cancel()
        rows = []
        fetchedAt = nil
        guard enabled, isDrafting, !hero.isEmpty, offers.count == 3,
              Set(offers.map(\.index)) == Set(0..<3),
              offers.allSatisfy({
                  // New cards can reach the public list before the local database.
                  guard let type = lookup($0.cardId)?.type else { return true }
                  return type != .hero && type != .hero_power && type != .invalid
              }) else { return }
        let current = offers.sorted { $0.index < $1.index }
        rows = current.map { .init(id: $0.index, cardID: $0.cardId, score: nil, isPackage: !$0.packageCardIds.isEmpty) }
        guard let heroClass = lookup(hero)?.cardClass, HearthArenaTierList.classKey(heroClass) != nil else {
            statusKey = "HearthArena_ClassUnavailable"
            return
        }
        if !heroPower.isEmpty {
            guard let powerClass = lookup(heroPower)?.cardClass, powerClass == heroClass else {
                statusKey = "HearthArena_DualClassUnsupported"
                return
            }
        }
        statusKey = "HearthArena_Loading"
        let requestGeneration = generation
        let loader = self.loader
        task = Task { [weak self] in
            let result: Result<HearthArenaRatingsResult, Error>
            do { result = .success(try await loader()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == requestGeneration, self.enabled, self.isDrafting else { return }
                switch result {
                case .success(let result):
                    self.rows = current.map {
                        .init(id: $0.index, cardID: $0.cardId,
                              score: result.list.score(cardID: $0.cardId, heroClass: heroClass),
                              isPackage: !$0.packageCardIds.isEmpty)
                    }
                    self.fetchedAt = result.list.fetchedAt
                    self.statusKey = result.isStale ? "HearthArena_Cached" : "HearthArena_BaseScore"
                case .failure:
                    self.statusKey = "HearthArena_Unavailable"
                }
            }
        }
    }
}
