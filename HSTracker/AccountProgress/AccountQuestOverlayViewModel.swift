import Combine
import Foundation

/// Presentation only; the account model remains the owner of log/session state.
final class AccountQuestOverlayViewModel: ObservableObject {
    @Published private(set) var rows: [AccountQuestOverlayRow] = []
    @Published private(set) var isShown = false
    @Published private(set) var isExpanded = false
    @Published private(set) var menuAvailable = false
    @Published private(set) var menuExpanded = false
    @Published private(set) var status = "AccountProgress_WaitingAccount"
    let placement = OverlayWidgetPlacement(widget: .accountQuests, isPlayer: true)

    private let model: AccountProgressModel
    private let experience: ExperienceCounterViewModel?
    private var subscriptions = Set<AnyCancellable>()

    init(model: AccountProgressModel = .shared, experience: ExperienceCounterViewModel? = nil) {
        self.model = model
        self.experience = experience
        // objectWillChange is delivered before a Published property's new value.
        // Hop to the run loop to project one consistent, updated model frame.
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.update()
        }.store(in: &subscriptions)
        experience?.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.update()
        }.store(in: &subscriptions)
        update()
    }

    func update() {
        rows = AccountQuestOverlayRow.rows(snapshot: model.session.snapshot,
            definitions: model.questDefinitions, estimate: model.questEstimate,
            hasVerifiedAccount: model.hasVerifiedAccount,
            showTraditional: model.showTraditionalQuests, showBattlegrounds: model.showBattlegroundsQuests)
        isShown = model.overlayEnabled && model.hasVisibleQuestCategories && model.overlayMatchActive
        menuAvailable = model.overlayEnabled && model.hasVisibleQuestCategories && model.menuActive && !model.overlayMatchActive
            && experience?.isShown == true
        // Data refreshes never open or close the list. Dismiss only when its
        // entry is unavailable (leaving the match or disabling the feature).
        if !isShown { isExpanded = false }
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
    }

    func toggleExpanded() {
        guard isShown else { return }
        isExpanded.toggle()
    }

    func toggleMenu() {
        guard menuAvailable else { return }
        menuExpanded.toggle()
        if menuExpanded { model.refresh(full: true) }
    }
}
