import Foundation
import CoreGraphics
import AppKit

/// A display-only projection. Confirmed account progress never includes a log estimate.
struct AccountQuestOverlayRow: Identifiable, Equatable {
    let id: Int
    let title: String
    let confirmed: Int
    let total: Int
    let quota: Int
    let estimatedDelta: Int?
    let schedule: AccountQuestSchedule
    let rewardTrackType: Int?
    let status: Int

    init(id: Int, title: String, confirmed: Int, total: Int, quota: Int,
         estimatedDelta: Int?, schedule: AccountQuestSchedule = .unknown,
         rewardTrackType: Int? = nil, status: Int = 0) {
        self.id = id
        self.title = title
        self.confirmed = confirmed
        self.total = total
        self.quota = quota
        self.estimatedDelta = estimatedDelta
        self.schedule = schedule
        self.rewardTrackType = rewardTrackType
        self.status = status
    }

    var fraction: Double {
        guard quota > 0 else { return 0 }
        return min(1, max(0, Double(total) / Double(quota)))
    }

    var isConfirmedComplete: Bool { status == 3 || (quota > 0 && confirmed >= quota) }

    var isEstimatedComplete: Bool {
        quota > 0 && !isConfirmedComplete && estimatedDelta != nil && total >= quota
    }

    var categoryKey: String {
        switch (rewardTrackType, schedule) {
        case (2, .daily): return "AccountProgress_CategoryBattlegroundsDaily"
        case (2, .weekly): return "AccountProgress_CategoryBattlegroundsWeekly"
        case (2, _): return "AccountProgress_CategoryBattlegroundsUnknown"
        case (7, .daily): return "AccountProgress_CategoryEventDaily"
        case (7, .weekly): return "AccountProgress_CategoryEventWeekly"
        case (_, .daily): return "AccountProgress_CategoryDaily"
        case (_, .weekly): return "AccountProgress_CategoryWeekly"
        default: return "AccountProgress_CategoryUnknown"
        }
    }

    var displayHeight: CGFloat {
        let measured = (title as NSString).boundingRect(
            with: CGSize(width: 304, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        return AccountQuestOverlayLayout.rowHeight + max(0, ceil(measured.height) - 36)
    }

    static func rows(snapshot: AccountProgressSnapshot?,
                     definitions: [Int: AccountQuestDefinition],
                     estimate: AccountQuestEstimate,
                     hasVerifiedAccount: Bool,
                     showTraditional: Bool = true, showBattlegrounds: Bool = false) -> [Self] {
        guard hasVerifiedAccount, let snapshot else { return [] }
        return snapshot.quests.compactMap { quest in
            // Client-verified states for granted/acknowledged rewards, rerolls,
            // resets, abandonment and expiration. Unknown values stay visible.
            guard !(4...9).contains(quest.status) else { return nil }
            let definition = definitions[quest.id]
            if let definition, !includes(definition) { return nil }
            let categoryEnabled = definition?.rewardTrackType == 2 ? showBattlegrounds : showTraditional
            guard categoryEnabled else { return nil }
            let quota = max(0, definition?.quota ?? 0)
            let progress = estimate.progress(for: quest, quota: quota)
            let description = plainText(definition?.text ?? "")
            let name = plainText(definition?.name ?? "")
            return Self(id: quest.id,
                        title: !description.isEmpty ? description : (!name.isEmpty ? name : "#\(quest.id)"),
                        confirmed: quest.progress,
                        total: progress?.total ?? quest.progress,
                        quota: quota,
                        estimatedDelta: progress?.delta,
                        schedule: definition?.schedule ?? .unknown,
                        rewardTrackType: definition?.rewardTrackType,
                        status: quest.status)
        }
    }

    private static func includes(_ definition: AccountQuestDefinition) -> Bool {
        switch definition.schedule {
        case .daily, .weekly:
            return true
        case .unknown:
            // Older caches and the public definition feed have no schedule.
            // Keep those account-assigned tasks as unclassified until native
            // metadata arrives; never infer a period from their wording or XP.
            return definition.rewardTrackType == 1 || definition.rewardTrackType == 2
        case .event:
            return false
        }
    }

    private static func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "(?i)<br\\s*/?>|</?(?:p|div)(?:\\s[^>]*)?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "[x]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Geometry in the overlay's existing 1080-tall reference canvas.
enum AccountQuestOverlayLayout {
    static let canvasHeight: CGFloat = 1080
    static let margin: CGFloat = 8
    static let headerSize = CGSize(width: 160, height: 48)
    static let panelWidth: CGFloat = 336
    static let rowHeight: CGFloat = 92
    static let panelChromeHeight: CGFloat = 68
    static let maximumPanelHeight: CGFloat = 650
    static let panelGap: CGFloat = 8

    /// Horizontal locates the header's right edge; vertical locates its top.
    /// Both are percentages, matching the saved overlay placement settings.
    static func headerFrame(canvasWidth: CGFloat, horizontal: Double, vertical: Double) -> CGRect {
        let width = canvasWidth.isFinite ? max(headerSize.width + margin * 2, canvasWidth)
            : headerSize.width + margin * 2
        let xPercent = horizontal.isFinite ? min(100, max(0, horizontal)) : 99
        let yPercent = vertical.isFinite ? min(100, max(0, vertical)) : 93
        let x = width * CGFloat(xPercent / 100) - headerSize.width
        let y = canvasHeight * CGFloat(yPercent / 100)
        return CGRect(x: min(width - margin - headerSize.width, max(margin, x)),
                      y: min(canvasHeight - margin - headerSize.height, max(margin, y)),
                      width: headerSize.width, height: headerSize.height)
    }

    static func panelFrame(header: CGRect, rowCount: Int) -> CGRect {
        // Clamp before multiplying so even a malformed row count cannot overflow.
        let visibleRows = min(7, max(1, rowCount))
        return panelFrame(header: header, contentHeight: CGFloat(visibleRows) * rowHeight)
    }

    static func panelFrame(header: CGRect, contentHeight: CGFloat) -> CGRect {
        let safeContentHeight = contentHeight.isFinite ? max(rowHeight, contentHeight) : rowHeight
        let desiredHeight = min(maximumPanelHeight, safeContentHeight + panelChromeHeight)
        let spaceAbove = max(0, header.minY - panelGap - margin)
        let spaceBelow = max(0, canvasHeight - margin - header.maxY - panelGap)
        let opensAbove = spaceAbove >= desiredHeight || spaceAbove > spaceBelow
        let height = min(desiredHeight, opensAbove ? spaceAbove : spaceBelow)
        let y = opensAbove ? header.minY - panelGap - height : header.maxY + panelGap
        return CGRect(x: max(margin, header.maxX - panelWidth), y: y,
                      width: panelWidth, height: height)
    }
}
