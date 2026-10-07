import Foundation
import CoreGraphics
import AppKit

/// A display-only projection. Confirmed account progress never includes a log estimate.
struct AccountQuestOverlayRow: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
    let confirmed: Int
    let total: Int
    let quota: Int
    let estimatedDelta: Int?
    let schedule: AccountQuestSchedule
    let rewardTrackType: Int?
    let status: Int
    let isChainQuest: Bool?

    init(id: Int, title: String, confirmed: Int, total: Int, quota: Int,
         estimatedDelta: Int?, schedule: AccountQuestSchedule = .unknown,
         rewardTrackType: Int? = nil, status: Int = 0, detail: String = "", isChainQuest: Bool? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.confirmed = confirmed
        self.total = total
        self.quota = quota
        self.estimatedDelta = estimatedDelta
        self.schedule = schedule
        self.rewardTrackType = rewardTrackType
        self.status = status
        self.isChainQuest = isChainQuest
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
        if rewardTrackType == 7 || schedule == .event {
            if rewardTrackType == 2 { return "AccountProgress_CategoryBattlegroundsEvent" }
            if isChainQuest == true { return "AccountProgress_CategoryEventChain" }
            if schedule == .daily { return "AccountProgress_CategoryEventDaily" }
            if schedule == .weekly { return "AccountProgress_CategoryEventWeekly" }
            // Non-chain membership alone does not prove a daily reset schedule.
            return "AccountProgress_CategoryEvent"
        }
        switch (rewardTrackType, schedule) {
        case (2, .daily): return "AccountProgress_CategoryBattlegroundsDaily"
        case (2, .weekly): return "AccountProgress_CategoryBattlegroundsWeekly"
        case (2, _): return "AccountProgress_CategoryBattlegroundsUnknown"
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
        let detailHeight = detail.isEmpty ? 0 : ceil((detail as NSString).boundingRect(
            with: CGSize(width: 304, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]).height) + 3
        return AccountQuestOverlayLayout.rowHeight + max(0, ceil(measured.height) - 36) + detailHeight
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
            // Event bonuses/co-op credit remain server-authoritative, even if
            // a future event reuses a known ordinary quest's ID and quota.
            let progress = definition?.isEvent == true ? nil : estimate.progress(for: quest, quota: quota,
                                                                                rewardTrack: definition?.rewardTrackType)
            let parts = displayText(definition?.text ?? "", separateNote: true)
            let description = parts.objective
            let name = plainText(definition?.name ?? "")
            return Self(id: quest.id,
                        title: !description.isEmpty ? description : (!name.isEmpty ? name : "#\(quest.id)"),
                        confirmed: quest.progress,
                        total: progress?.total ?? quest.progress,
                        quota: quota,
                        estimatedDelta: progress?.delta,
                        schedule: definition?.schedule ?? .unknown,
                        rewardTrackType: definition?.rewardTrackType,
                        status: quest.status, detail: parts.note, isChainQuest: definition?.isChainQuest)
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
            return [1, 2, 7].contains(definition.rewardTrackType)
        case .event:
            return true
        }
    }

    /// Split the client's trailing italic note for display, never to evaluate
    /// translated rules. Unknown formats remain visible in the full objective.
    private static func displayText(_ value: String, separateNote: Bool) -> (objective: String, note: String) {
        guard separateNote,
              let regex = try? NSRegularExpression(pattern: "(?is)<i>([^<]*(?:<(?!/?i>)[^>]*>[^<]*)*)</i>\\s*$"),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let full = Range(match.range, in: value), let note = Range(match.range(at: 1), in: value) else {
            return (plainText(value), "")
        }
        let objective = plainText(String(value[..<full.lowerBound]))
        guard !objective.isEmpty else { return (plainText(value), "") }
        return (objective, plainText(String(value[note])))
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
