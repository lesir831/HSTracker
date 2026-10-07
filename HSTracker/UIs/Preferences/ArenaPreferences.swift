//
//  ArenaPreferences.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

/// Arenasmith options. Mirrors HDT's `FlyoutControls/Options/Overlay/OverlayArena`,
/// which lives under its Overlay page; HSTracker gives each game mode its own
/// pane, so this follows BattlegroundsPreferences instead.
class ArenaPreferences: PreferencePaneController, PreferencePane {
    private var hearthArenaCheckbox: NSButton?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let stack = view as? NSStackView else { return }
        let checkbox = NSButton(checkboxWithTitle: String.localizedString("HearthArena_Enable", comment: ""),
                                target: self, action: #selector(hearthArenaChanged(_:)))
        checkbox.state = Settings.showHearthArenaScores ? .on : .off
        stack.addArrangedSubview(checkbox)
        hearthArenaCheckbox = checkbox
        let help = NSTextField(wrappingLabelWithString: String.localizedString("HearthArena_Help", comment: ""))
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(help)
        let link = NSButton(title: String.localizedString("HearthArena_OpenTierList", comment: ""),
                            target: self, action: #selector(openHearthArena))
        link.bezelStyle = .inline
        stack.addArrangedSubview(link)
        for subview in [checkbox, help, link] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            subview.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
            subview.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
        }
    }

    @objc private func hearthArenaChanged(_ sender: NSButton) {
        Settings.showHearthArenaScores = sender.state == .on
    }

    @objc private func openHearthArena() { NSWorkspace.shared.open(HearthArenaTierList.sourceURL) }
    var preferencePaneIdentifier = PreferencePaneIdentifier.arena

    var preferencePaneTitle = String.localizedString("Arena", comment: "")

    var preferencePaneIcon = NSImage(named: "settings-arena")!

    @IBOutlet var enableArenasmithOverlay: NSButton!
    @IBOutlet var showArenasmithPreLobby: NSButton!
    @IBOutlet var showArenaHeroPicking: NSButton!
    @IBOutlet var showArenasmithScore: NSButton!
    @IBOutlet var showArenaRelatedCards: NSButton!
    @IBOutlet var showArenaDeckSynergies: NSButton!
    @IBOutlet var showArenaRedraftDiscard: NSButton!
    @IBOutlet var showOpponentArenaPackages: NSButton!

    override func viewWillAppear() {
        super.viewWillAppear()
        hearthArenaCheckbox?.state = Settings.showHearthArenaScores ? .on : .off

        guard enableArenasmithOverlay != nil else {
            return
        }

        enableArenasmithOverlay.state = Settings.enableArenasmithOverlay ? .on : .off
        showArenasmithPreLobby.state = Settings.showArenasmithPreLobby ? .on : .off
        showArenaHeroPicking.state = Settings.showArenaHeroPicking ? .on : .off
        showArenasmithScore.state = Settings.showArenasmithScore ? .on : .off
        showArenaRelatedCards.state = Settings.showArenaRelatedCards ? .on : .off
        showArenaDeckSynergies.state = Settings.showArenaDeckSynergies ? .on : .off
        showArenaRedraftDiscard.state = Settings.showArenaRedraftDiscard ? .on : .off
        // The stored setting is negative (hide), the checkbox is positive (show),
        // matching HDT's label.
        showOpponentArenaPackages.state = Settings.hideOpponentArenaPackages ? .off : .on

        updateEnabledState()
    }

    /// Every other checkbox is a sub-option of the overlay as a whole, so all
    /// seven grey out when it is off - HDT binds each one's IsEnabled to the
    /// Enable Arenasmith checkbox.
    private func updateEnabledState() {
        let enabled = Settings.enableArenasmithOverlay
        for checkbox in [showArenasmithPreLobby, showArenaHeroPicking, showArenasmithScore,
                         showArenaRelatedCards, showArenaDeckSynergies, showArenaRedraftDiscard,
                         showOpponentArenaPackages] {
            checkbox?.isEnabled = enabled
        }
    }

    @IBAction func checkboxClicked(_ sender: NSButton) {
        let isOn = sender.state == .on

        if sender == enableArenasmithOverlay {
            Settings.enableArenasmithOverlay = isOn
            updateEnabledState()
        } else if sender == showArenasmithPreLobby {
            Settings.showArenasmithPreLobby = isOn
        } else if sender == showArenaHeroPicking {
            Settings.showArenaHeroPicking = isOn
        } else if sender == showArenasmithScore {
            Settings.showArenasmithScore = isOn
        } else if sender == showArenaRelatedCards {
            Settings.showArenaRelatedCards = isOn
        } else if sender == showArenaDeckSynergies {
            Settings.showArenaDeckSynergies = isOn
        } else if sender == showArenaRedraftDiscard {
            Settings.showArenaRedraftDiscard = isOn
        } else if sender == showOpponentArenaPackages {
            Settings.hideOpponentArenaPackages = !isOn
        }

        // The overlay reads these settings directly, so a change while the draft
        // screen is up needs to redraw rather than wait for the next pick.
        let overlay = AppDelegate.instance().coreManager?.game.windowManager.rootOverlay?.viewModel
        overlay?.arenaPickHelper.settingsChanged()
        overlay?.arenaPreDraft.settingsChanged()
    }
}

// MARK: - Preferences

extension PreferencePaneIdentifier {
    static let arena = Self("arena")
}
