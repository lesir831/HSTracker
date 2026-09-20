import Combine
import Foundation

/// Presentation only; the account model remains the owner of log/session state.
final class AccountQuestOverlayViewModel: ObservableObject {
    @Published private(set) var rows: [AccountQuestOverlayRow] = []
    @Published private(set) var isShown = false
    @Published private(set) var isExpanded = false
    @Published private(set) var isPinned: Bool
    @Published private(set) var menuAvailable = false
    @Published private(set) var menuExpanded = false
    @Published private(set) var status = "AccountProgress_WaitingAccount"
    let placement = OverlayWidgetPlacement(widget: .accountQuests, isPlayer: true)

    private let model: AccountProgressModel
    private let experience: ExperienceCounterViewModel?
    private var subscriptions = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var hovered = false
    private var hoverExpanded = false
    private var revealing = false

    init(model: AccountProgressModel = .shared, pinned: Bool? = nil, experience: ExperienceCounterViewModel? = nil) {
        self.model = model
        self.experience = experience
        self.isPinned = pinned ?? Settings.accountQuestOverlayPinned
        // objectWillChange is delivered before a Published property's new value.
        // Hop to the run loop to project one consistent, updated model frame.
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.update()
        }.store(in: &subscriptions)
        experience?.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.update()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: Notification.Name(Settings.account_quest_overlay_pinned))
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.isPinned = Settings.accountQuestOverlayPinned
                self?.updateExpanded()
            }.store(in: &subscriptions)
        update()
    }

    deinit {
        hoverWork?.cancel()
        revealWork?.cancel()
    }

    func update() {
        let wasShown = isShown
        let wasEmpty = rows.isEmpty
        let previous = Dictionary(rows.map { ($0.id, $0.total) }, uniquingKeysWith: { _, last in last })
        rows = AccountQuestOverlayRow.rows(snapshot: model.session.snapshot,
            definitions: model.questDefinitions, estimate: model.questEstimate,
            hasVerifiedAccount: model.hasVerifiedAccount,
            showTraditional: model.showTraditionalQuests, showBattlegrounds: model.showBattlegroundsQuests)
        isShown = model.overlayEnabled && model.hasVisibleQuestCategories && model.overlayMatchActive
        menuAvailable = model.overlayEnabled && model.hasVisibleQuestCategories && model.menuActive && !model.overlayMatchActive
            && experience?.isShown == true
        if !menuAvailable { menuExpanded = false }
        if !model.hasVerifiedAccount {
            status = model.message == "AccountProgress_UnsupportedClient"
                ? model.message : "AccountProgress_WaitingAccount"
        } else if rows.isEmpty {
            status = "AccountProgress_NoQuests"
        } else if model.questDefinitions.isEmpty {
            status = "AccountProgress_DefinitionsUnavailable"
        } else {
            status = model.questTrackingStatus
        }
        guard isShown else {
            hoverWork?.cancel()
            revealWork?.cancel()
            hovered = false
            hoverExpanded = false
            revealing = false
            updateExpanded()
            return
        }
        let increased = rows.contains { row in previous[row.id].map { row.total > $0 } ?? false }
        if !wasShown || (wasEmpty && !rows.isEmpty) || increased { reveal() }
        updateExpanded()
    }

    func setHovered(_ value: Bool) {
        guard isShown else { return }
        guard hovered != value else { return }
        hovered = value
        hoverWork?.cancel()
        // Also delay closing so a cursor can cross the gap into the list.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverExpanded = value
            self.updateExpanded()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (value ? 0.15 : 0.25), execute: work)
    }

    func toggleMenu() {
        guard menuAvailable else { return }
        menuExpanded.toggle()
        if menuExpanded { model.refresh(full: true) }
    }

    func togglePinned() {
        isPinned.toggle()
        Settings.accountQuestOverlayPinned = isPinned
        if !isPinned {
            hoverExpanded = false
            expireReveal()
        }
        updateExpanded()
    }

    private func reveal() {
        revealWork?.cancel()
        revealing = true
        let work = DispatchWorkItem { [weak self] in self?.expireReveal() }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func expireReveal() {
        revealWork?.cancel()
        revealing = false
        updateExpanded()
    }

    private func updateExpanded() {
        isExpanded = isShown && (isPinned || hoverExpanded || revealing)
    }
}
