import AppKit
import SwiftUI

final class AccountProgressWindow: NSWindowController, NSWindowDelegate {
    static let shared = AccountProgressWindow()

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = String.localizedString("AccountProgress_Title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AccountProgressView(model: .shared))
        panel.minSize = NSSize(width: 400, height: 420)
        super.init(window: panel)
        panel.delegate = self
        panel.setFrameAutosaveName("AccountProgressWindow")
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func open() {
        AccountProgressModel.shared.open()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AccountProgressModel.shared.panelVisible = false
    }
}

private struct AccountProgressView: View {
    @ObservedObject var model: AccountProgressModel
    @State private var search = ""
    @State private var onlyPinned = true

    private func text(_ key: String) -> String { String.localizedString(key, comment: "") }

    private var definitions: [Int: AccountAchievementDefinition] {
        model.achievementDefinitions
    }

    private var quests: [AccountQuestOverlayRow] {
        AccountQuestOverlayRow.rows(snapshot: model.session.snapshot,
            definitions: model.questDefinitions, estimate: model.questEstimate,
            hasVerifiedAccount: model.hasVerifiedAccount,
            showTraditional: model.showTraditionalQuests, showBattlegrounds: model.showBattlegroundsQuests)
    }

    private var achievements: [AccountProgressRecord] {
        let definitions = self.definitions
        return Array((model.session.snapshot?.achievements ?? []).filter { record in
            (!onlyPinned || model.pinned.contains(record.id)) &&
                (search.isEmpty || String(record.id).contains(search) ||
                 (definitions[record.id]?.name.localizedCaseInsensitiveContains(search) ?? false) ||
                 (definitions[record.id]?.description.localizedCaseInsensitiveContains(search) ?? false))
        }.sorted { lhs, rhs in
            let left = model.pinned.contains(lhs.id)
            let right = model.pinned.contains(rhs.id)
            return left != right ? left : lhs.id < rhs.id
        }.prefix(200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text(model.message)).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(text(model.refreshing ? "AccountProgress_Refreshing" : "AccountProgress_Refresh")) {
                    model.loadQuestDefinitions()
                    model.refresh(full: true)
                }.disabled(model.refreshing)
            }
            Text(text(model.questTrackingStatus)).font(.caption).foregroundColor(.secondary)
            if let snapshot = model.session.snapshot, model.hasVerifiedAccount {
                Text(text("AccountProgress_LastSync") + " " + DateFormatter.localizedString(from: snapshot.capturedAt, dateStyle: .short, timeStyle: .medium))
                    .font(.caption).foregroundColor(.secondary)
                Text(text("AccountProgress_Quests")).font(.headline)
                if model.questDefinitions.isEmpty {
                    Text(text("AccountProgress_DefinitionsUnavailable")).font(.caption).foregroundColor(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(quests) { quest in questRow(quest) }
                        if quests.isEmpty { Text(text("AccountProgress_NoQuests")) }
                    }
                }.frame(maxHeight: 220)
                if model.definitionError {
                    Text(text("AccountProgress_DefinitionRefreshFailed")).font(.caption).foregroundColor(.secondary)
                }
                Text(text("AccountProgress_QuestRefreshNote")).font(.caption).foregroundColor(.secondary)
                Divider()
                HStack {
                    Text(text("AccountProgress_Achievements")).font(.headline)
                    Spacer()
                    Toggle(text("AccountProgress_OnlyPinned"), isOn: $onlyPinned)
                }
                TextField(text("AccountProgress_Search"), text: $search).textFieldStyle(RoundedBorderTextFieldStyle())
                if snapshot.definitions.isEmpty {
                    Text(text("AccountProgress_OpenAchievements")).font(.caption).foregroundColor(.secondary)
                }
                if onlyPinned && model.pinned.isEmpty {
                    Text(text("AccountProgress_EmptyPins")).font(.caption).foregroundColor(.secondary)
                }
                List(achievements) { record in
                    HStack(alignment: .top) {
                        Button(model.pinned.contains(record.id) ? "★" : "☆") { model.togglePin(record.id) }
                            .buttonStyle(BorderlessButtonStyle())
                            .accessibility(label: Text(text("AccountProgress_Pin")))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(self.definitions[record.id]?.name ?? "#\(record.id)").font(.headline)
                            if let definition = self.definitions[record.id] {
                                Text(plainDescription(definition.description)).font(.caption).foregroundColor(.secondary)
                            }
                            HStack {
                                Text(self.totalText(record)).font(Font.body.monospacedDigit())
                                if let delta = self.model.session.delta(for: record.id) {
                                    Text(self.text("AccountProgress_ThisGame") + " +\(delta)").foregroundColor(.secondary)
                                } else if self.model.pinned.contains(record.id) {
                                    Text(self.text("AccountProgress_LiveUnavailable")).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }.padding(.vertical, 3)
                }
                Text(text("AccountProgress_SearchLimit")).font(.caption).foregroundColor(.secondary)
            } else {
                Spacer()
                Text(text("AccountProgress_LoginPrompt")).foregroundColor(.secondary)
                Spacer()
            }
        }.padding(16)
    }

    private func questRow(_ quest: AccountQuestOverlayRow) -> some View {
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(quest.title.hasPrefix("#") ? text("AccountProgress_QuestDetailsPending") : quest.title)
                if !quest.detail.isEmpty {
                    Text(quest.detail).font(.caption).foregroundColor(.secondary)
                }
                Text(text(quest.categoryKey)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(quest.quota > 0 ? "\(quest.total) / \(quest.quota)" : "\(quest.confirmed) / —")
                    .font(Font.body.monospacedDigit())
                if quest.isConfirmedComplete {
                    Text(text("AccountProgress_QuestComplete")).font(.caption).foregroundColor(.secondary)
                } else if let delta = quest.estimatedDelta {
                    Text(text("AccountProgress_Estimate") + " +\(delta)")
                        .font(.caption).foregroundColor(.secondary)
                    Text(text("AccountProgress_Confirmed") + " \(quest.confirmed)")
                        .font(.caption).foregroundColor(.secondary)
                } else if model.questEstimate.matchID != nil {
                    Text(text("AccountProgress_AfterMatch")).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func plainDescription(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[x]", with: "")
    }

    private func totalText(_ record: AccountProgressRecord) -> String {
        let value = model.session.liveTotal(for: record.id) ?? record.progress
        if let quota = definitions[record.id]?.quota, quota > 0 { return "\(value) / \(quota)" }
        return String(value)
    }
}
