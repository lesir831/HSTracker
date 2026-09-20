import AppKit
import Combine
import Foundation

final class AccountProgressModel: ObservableObject {
    static let shared = AccountProgressModel()
    @Published private(set) var session = AccountProgressSession()
    @Published private(set) var questEstimate = AccountQuestEstimate()
    @Published private(set) var hasVerifiedAccount = false
    @Published private(set) var pinned = Set<Int>()
    @Published private(set) var refreshing = false
    @Published private(set) var message = "AccountProgress_NotSynced"
    @Published private(set) var questDefinitions: [Int: AccountQuestDefinition] = [:]
    @Published private(set) var definitionError = false
    @Published private(set) var achievementDefinitions: [Int: AccountAchievementDefinition] = [:]
    @Published private(set) var overlayEnabled: Bool
    @Published private(set) var showTraditionalQuests: Bool
    @Published private(set) var showBattlegroundsQuests: Bool
    @Published private(set) var overlayMatchActive = false
    @Published private(set) var menuActive = false
    var panelVisible = false

    private let queue = DispatchQueue(label: "net.hearthsim.hstracker.accountProgress", qos: .utility)
    private var timer: Timer?
    private var enabled: Bool
    typealias Reader = (Bool) throws -> (scope: String, reading: AccountProgressReading)
    private let reader: Reader
    private let automaticallyPoll: Bool
    private let persists: Bool
    private var currentMatch: String?
    private var baselinePending = false
    private var estimatesEligible = false
    private var revision = 0
    private var pendingFullRefresh = false
    private var scene: String?
    private var loadingDefinitions = false
    private var fallbackQuestDefinitions: [Int: AccountQuestDefinition]
    private var nativeQuestDefinitionsByID: [Int: AccountNativeQuestDefinition] = [:]
    private var nativeQuestDefinitionScope: String?
    private var fallbackDefinitionError = false
    private var lastMenuRefresh = Date.distantPast

    var questTrackingStatus: String {
        guard currentMatch != nil else { return "AccountProgress_NoActiveMatch" }
        guard questEstimate.matchID != nil else {
            return overlayMatchActive && estimatesEligible ? "AccountProgress_JoinedMidMatch" : "AccountProgress_MatchNotEstimated"
        }
        guard hasVerifiedAccount else { return "AccountProgress_WaitingAccount" }
        return questEstimate.hasBaseline ? "AccountProgress_LiveTracking" : "AccountProgress_WaitingBaseline"
    }

    init(enabled: Bool? = nil, automaticallyPoll: Bool = true, persists: Bool = true,
         overlayEnabled: Bool? = nil,
         definitions: [Int: AccountQuestDefinition] = [:],
         showTraditionalQuests: Bool? = nil, showBattlegroundsQuests: Bool? = nil,
         reader: @escaping Reader = { try MirrorHelper.readAccountProgress(includeSnapshot: $0) }) {
        self.enabled = enabled ?? Settings.accountQuestOverlayEnabled
        self.overlayEnabled = overlayEnabled ?? Settings.accountQuestOverlayEnabled
        self.showTraditionalQuests = showTraditionalQuests ?? Settings.accountQuestShowTraditional
        self.showBattlegroundsQuests = showBattlegroundsQuests ?? Settings.accountQuestShowBattlegrounds
        self.automaticallyPoll = automaticallyPoll
        self.persists = persists
        self.reader = reader
        self.questDefinitions = definitions
        self.fallbackQuestDefinitions = definitions
    }

    /// Called before the log reader starts, so release builds capture the
    /// opening baseline without requiring the diagnostic window to be opened.
    func start() {
        guard enabled else { return }
        startTimer()
        if automaticallyPoll { loadQuestDefinitions() }
        refresh(full: true)
    }

    func setOverlayEnabled(_ value: Bool) {
        overlayEnabled = value
        if persists { Settings.accountQuestOverlayEnabled = value }
        if value {
            enabled = true
            start()
        }
    }

    var hasVisibleQuestCategories: Bool { showTraditionalQuests || showBattlegroundsQuests }

    /// Filter presentation only; preserve the complete authoritative snapshot
    /// and existing match estimates when a category is hidden.
    func setQuestCategories(showTraditional: Bool, showBattlegrounds: Bool) {
        showTraditionalQuests = showTraditional
        showBattlegroundsQuests = showBattlegrounds
        if persists {
            Settings.accountQuestShowTraditional = showTraditional
            Settings.accountQuestShowBattlegrounds = showBattlegrounds
        }
    }

    func open() {
        enabled = true
        panelVisible = true
        UserDefaults.standard.set(true, forKey: "account_progress_enabled")
        startTimer()
        loadQuestDefinitions()
        refresh(full: true)
    }

    private func startTimer() {
        guard automaticallyPoll, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.currentMatch != nil, self.panelVisible || self.overlayEnabled || !self.pinned.isEmpty {
                self.refresh(full: false)
            } else if self.panelVisible || self.overlayEnabled, self.lastMenuRefresh.timeIntervalSinceNow < -15 {
                self.lastMenuRefresh = Date()
                if self.questDefinitions.isEmpty || self.definitionError { self.loadQuestDefinitions() }
                self.refresh(full: true)
            }
        }
    }

    func sceneChanged(_ next: String) {
        guard enabled, next != scene else { return }
        scene = next
        // Mirror scene polling can lag the log's gameStart. It may refresh a
        // snapshot, but must never terminate the log-owned match session.
        refresh(full: true)
    }

    func beginMatch(_ id: String, spectator: Bool, questEligible: Bool, overlayEligible: Bool? = nil) {
        revision += 1
        menuActive = false
        currentMatch = spectator ? nil : id
        overlayMatchActive = !spectator && (overlayEligible ?? questEligible) && !id.isEmpty
        estimatesEligible = questEligible && !spectator
        baselinePending = !spectator && enabled
        session.endMatch()
        questEstimate.beginMatch(id, eligible: enabled && !spectator && questEligible)
        guard enabled else { return }
        if automaticallyPoll && questDefinitions.isEmpty { loadQuestDefinitions() }
        logger.debug("Quest tracking started: eligible=\(!spectator && questEligible), hasMatchID=\(!id.isEmpty)")
        startTimer()
        refresh(full: true)
    }

    func endMatch() {
        revision += 1
        currentMatch = nil
        overlayMatchActive = false
        estimatesEligible = false
        baselinePending = false
        session.endMatch()
        questEstimate.endMatch()
        guard enabled else { return }
        logger.debug("Quest tracking ended by game lifecycle")
        // The log result can precede the server's account-state update.
        if automaticallyPoll {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(full: true) }
        }
    }

    func gameClosed() {
        menuActive = false
        endMatch()
        session.switchAccount(to: nil)
        setNativeQuestDefinitionScope(nil)
        achievementDefinitions = [:]
        hasVerifiedAccount = false
        message = "AccountProgress_NotSynced"
    }

    /// Driven by the same log scenes that show the existing experience bar.
    func setMenuActive(_ value: Bool) {
        menuActive = value
    }

    func refresh(full: Bool) {
        guard enabled else { return }
        if refreshing {
            pendingFullRefresh = pendingFullRefresh || full
            return
        }
        refreshing = true
        let requestRevision = revision
        let includeSnapshot = full || baselinePending || session.snapshot == nil
        queue.async {
            let result = Result { try self.reader(includeSnapshot) }
            DispatchQueue.main.async {
                self.refreshing = false
                guard requestRevision == self.revision else {
                    self.refresh(full: true)
                    return
                }
                switch result {
                case .success(let frame):
                    self.hasVerifiedAccount = true
                    let previousScope = self.session.scope
                    let changed = previousScope != frame.scope
                    if changed {
                        self.session.switchAccount(to: frame.scope)
                        self.setNativeQuestDefinitionScope(frame.scope)
                        self.achievementDefinitions = [:]
                        self.pinned = Set(UserDefaults.standard.array(forKey: "account_progress_pins." + frame.scope) as? [Int] ?? [])
                        self.loadCache(scope: frame.scope)
                        // An account switch during a match invalidates its opening baseline.
                        if previousScope != nil {
                            self.currentMatch = nil
                            self.overlayMatchActive = false
                            self.baselinePending = false
                            self.questEstimate.endMatch()
                        }
                    }
                    if let snapshot = frame.reading.snapshot {
                        self.questEstimate.bind(snapshot, scope: frame.scope)
                        self.applySnapshot(snapshot, scope: frame.scope)
                        self.saveCache(snapshot, scope: frame.scope)
                        if self.baselinePending, let match = self.currentMatch {
                            self.session.beginMatch(match, baseline: snapshot)
                            self.baselinePending = false
                        }
                    }
                    if let match = self.currentMatch {
                        self.session.updateLive(frame.reading.inGame, matchID: match)
                    }
                    self.message = "AccountProgress_Synced"
                    if changed && frame.reading.snapshot == nil { self.pendingFullRefresh = true }
                case .failure(let error):
                    let failure = error as? AccountProgressReadFailure
                    self.hasVerifiedAccount = failure?.scope != nil && failure?.scope == self.session.scope
                    // An unavailable identity is not an account switch. Hide the
                    // data until reverified, retain the opening baseline and log
                    // totals, and discard them only for a confirmed different account.
                    if let scope = failure?.scope, scope != self.session.scope {
                        let isAccountSwitch = self.session.scope != nil
                        self.session.switchAccount(to: failure?.scope)
                        self.setNativeQuestDefinitionScope(scope)
                        self.achievementDefinitions = [:]
                        self.pinned = Set(UserDefaults.standard.array(forKey: "account_progress_pins." + (failure?.scope ?? "")) as? [Int] ?? [])
                        if isAccountSwitch {
                            self.currentMatch = nil
                            self.overlayMatchActive = false
                            self.baselinePending = false
                            self.questEstimate.endMatch()
                        }
                        if let scope = failure?.scope { self.loadCache(scope: scope) }
                    }
                    self.session.invalidateLive()
                    self.message = failure?.reason.hasPrefix("unsupported") == true
                        ? "AccountProgress_UnsupportedClient" : "AccountProgress_ReadFailed"
                }
                if self.pendingFullRefresh {
                    self.pendingFullRefresh = false
                    self.refresh(full: true)
                }
            }
        }
    }

    func togglePin(_ id: Int) {
        guard let scope = session.scope else { return }
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        UserDefaults.standard.set(pinned.sorted(), forKey: "account_progress_pins." + scope)
    }

    func observeQuest(_ metric: AccountQuestEstimate.Metric, total: Int, matchID: String, isLocalPlayer: Bool) {
        guard enabled else { return }
        if questEstimate.observe(metric, total: total, matchID: matchID, isLocalPlayer: isLocalPlayer) {
            logger.debug("Quest estimate sample: \(metric.rawValue)=\(total)")
        }
    }

    private struct Cache: Codable {
        let version: Int
        let scope: String
        let snapshot: AccountProgressSnapshot
    }

    private func cacheURL(scope: String) -> URL? {
        guard scope.count == 64, scope.allSatisfy({ $0.isHexDigit }),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("HSTracker/AccountProgress").appendingPathComponent(scope + ".json")
    }

    private func loadCache(scope: String) {
        guard persists else { return }
        guard let url = cacheURL(scope: scope), let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == 1, cache.scope == scope else { return }
        applySnapshot(cache.snapshot, scope: scope)
    }

    private func saveCache(_ snapshot: AccountProgressSnapshot, scope: String) {
        guard persists else { return }
        guard let url = cacheURL(scope: scope) else { return }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Cache(version: 1, scope: scope, snapshot: snapshot)).write(to: url, options: .atomic)
            } catch {
                logger.warning("Could not persist account progress cache")
            }
        }
    }

    private func applySnapshot(_ snapshot: AccountProgressSnapshot, scope: String) {
        guard session.scope == scope else { return }
        setNativeQuestDefinitionScope(scope)
        let currentQuestIDs = Set(snapshot.quests.map(\.id))
        nativeQuestDefinitionsByID = nativeQuestDefinitionsByID.filter { currentQuestIDs.contains($0.key) }
        for native in snapshot.nativeQuestDefinitions where currentQuestIDs.contains(native.id) {
            if native.poolType == nil, let previous = nativeQuestDefinitionsByID[native.id],
               previous.questPoolID == native.questPoolID {
                // The quest record and its pool table are optional independent
                // reads. Reuse a missing cadence only while the pool ID agrees.
                nativeQuestDefinitionsByID[native.id] = AccountNativeQuestDefinition(
                    id: native.id, name: native.name, description: native.description,
                    quota: native.quota, rewardTrackType: native.rewardTrackType,
                    questPoolID: native.questPoolID, poolType: previous.poolType)
            } else {
                nativeQuestDefinitionsByID[native.id] = native
            }
        }
        session.apply(snapshot, scope: scope)
        rebuildQuestDefinitions()
        achievementDefinitions = Dictionary(snapshot.definitions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        pinned = session.advancedPins(pinned)
        if persists { UserDefaults.standard.set(pinned.sorted(), forKey: "account_progress_pins." + scope) }
    }

    private func setNativeQuestDefinitionScope(_ scope: String?) {
        guard nativeQuestDefinitionScope != scope else { return }
        nativeQuestDefinitionScope = scope
        nativeQuestDefinitionsByID.removeAll()
        rebuildQuestDefinitions()
    }

    /// Native metadata matches the running client and supplies cadence; public
    /// definitions are only a text fallback when that metadata is unavailable.
    private func rebuildQuestDefinitions() {
        var definitions = fallbackQuestDefinitions
        // Optional DBF reads can be incomplete while the server snapshot is
        // valid. Keep prior definitions only for this account's current task IDs;
        // a replacement definition, removal, account switch or close invalidates them.
        for native in nativeQuestDefinitionsByID.values {
            let fallback = fallbackQuestDefinitions[native.id]
            definitions[native.id] = AccountQuestDefinition(
                id: native.id,
                description: native.description.isEmpty ? (fallback?.description ?? "") : native.description,
                quota: native.quota, rewardTrackType: native.rewardTrackType,
                name: native.name.isEmpty ? (fallback?.name ?? "") : native.name,
                schedule: AccountQuestSchedule(poolType: native.poolType))
        }
        questDefinitions = definitions
        let active = session.snapshot?.quests.filter { !(4...9).contains($0.status) } ?? []
        definitionError = fallbackDefinitionError && active.contains {
            definitions[$0.id]?.description.isEmpty != false
        }
    }

    func loadQuestDefinitions() {
        guard !loadingDefinitions else { return }
        loadingDefinitions = true
        let locale = Settings.hearthstoneLanguage?.rawValue ?? "enUS"
        guard let url = URL(string: "https://static.firestoneapp.com/data/quests/quests-data_\(locale).gz.json") else {
            loadingDefinitions = false
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            let decoded: AccountQuestDefinitions?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 4 * 1024 * 1024 {
                decoded = try? JSONDecoder().decode(AccountQuestDefinitions.self, from: data)
            } else { decoded = nil }
            DispatchQueue.main.async {
                self.loadingDefinitions = false
                guard let decoded, !decoded.quests.isEmpty else {
                    self.fallbackDefinitionError = true
                    self.rebuildQuestDefinitions()
                    return
                }
                guard locale == (Settings.hearthstoneLanguage?.rawValue ?? "enUS") else { return }
                self.fallbackQuestDefinitions = Dictionary(decoded.quests.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                self.fallbackDefinitionError = false
                self.rebuildQuestDefinitions()
            }
        }.resume()
    }
}
