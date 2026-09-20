import SwiftUI

/// A child of RootOverlay's scaled canvas, with the same hover and drag
/// plumbing as its existing task lists. Only the header takes clicks.
struct AccountQuestOverlayView: View {
    @ObservedObject var viewModel: AccountQuestOverlayViewModel
    @ObservedObject var placement: OverlayWidgetPlacement
    let canvasWidth: CGFloat
    let canvasSize: CGSize
    let isLocked: Bool

    private var headerFrame: CGRect {
        AccountQuestOverlayLayout.headerFrame(canvasWidth: canvasWidth,
            horizontal: placement.horizontal, vertical: placement.vertical)
    }
    private var panelFrame: CGRect {
        AccountQuestOverlayLayout.panelFrame(header: headerFrame,
            contentHeight: viewModel.rows.reduce(0) { $0 + $1.displayHeight })
    }
    private var expanded: Bool { viewModel.isExpanded && isLocked }
    private var scale: CGFloat { canvasSize.height / 1080 }
    private var needsScroll: Bool {
        viewModel.rows.reduce(0) { $0 + $1.displayHeight }
            > panelFrame.height - AccountQuestOverlayLayout.panelChromeHeight
    }
    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
    private func text(_ key: String) -> String { String.localizedString(key, comment: "") }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isShown {
                if expanded {
                    panel
                        .frame(width: panelFrame.width, height: panelFrame.height)
                        .offset(x: panelFrame.minX, y: panelFrame.minY)
                        .allowsHitTesting(needsScroll)
                        .preference(key: InteractiveRegionPreferenceKey.self,
                                    value: needsScroll ? [pixels(panelFrame)] : [])
                }
                Button(action: { viewModel.togglePinned() }) { header }
                    .buttonStyle(PlainButtonStyle())
                    .accessibility(label: Text(text(viewModel.isPinned
                        ? "AccountProgress_UnpinOverlay" : "AccountProgress_PinOverlay")))
                    .frame(width: headerFrame.width, height: headerFrame.height)
                    .offset(x: headerFrame.minX, y: headerFrame.minY)
                    .preference(key: InteractiveRegionPreferenceKey.self,
                                value: isLocked ? [pixels(headerFrame)] : [])
                if !isLocked {
                    OverlayWidgetMovableBox(placement: placement, frame: headerFrame,
                                            canvasSize: canvasSize, canvasScale: scale)
                }
            }
        }
        .frame(width: canvasWidth, height: 1080, alignment: .topLeading)
        // Include the gap as hover-only, so crossing from button to panel
        // cannot close it. Empty canvas pixels still pass every click through.
        .preference(key: HoverRegionPreferenceKey.self,
                    value: viewModel.isShown && isLocked
                        ? [HoverRegion(id: HoverRegionID.accountQuests,
                                       rect: pixels(expanded ? headerFrame.union(panelFrame) : headerFrame))] : [])
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            Image("hs_banner").resizable(capInsets: EdgeInsets(top: 12, leading: 25, bottom: 12, trailing: 25))
                .frame(width: 150, height: 44).offset(x: 10)
            Image("xp_scroll_item").resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(width: 48, height: 48)
            HStack(spacing: 5) {
                Text(text("AccountProgress_OverlayTitle"))
                if !viewModel.rows.isEmpty { Text("\(viewModel.rows.count)") }
            }
            .font(Settings.usesLatinCardFont ? .custom("ChunkFive", size: 16) : .system(size: 16, weight: .bold))
            .foregroundColor(Color(hex: "#352211"))
            // Center in the banner's front face; its folded tails extend below it.
            .frame(width: 106, height: 44).offset(x: 45, y: -6)
        }
        .frame(width: 160, height: 48)
    }

    private var panel: some View {
        AccountQuestOverlayPanel(rows: viewModel.rows, status: viewModel.status,
                                 inMatch: true, needsScroll: needsScroll)
    }
}

/// Shared material and rows for match and main-menu presentation.
struct AccountQuestOverlayPanel: View {
    let rows: [AccountQuestOverlayRow]
    let status: String
    let inMatch: Bool
    let needsScroll: Bool
    private func text(_ key: String) -> String { String.localizedString(key, comment: "") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("AccountProgress_Quests")).font(.system(size: 15, weight: .bold))
                Spacer()
            }
            .foregroundColor(Color(hex: "#352211"))
            .padding(.horizontal, 32).padding(.top, 8).frame(height: 40)
            if rows.isEmpty {
                Text(text(status))
                    .font(.system(size: 13)).foregroundColor(Color(hex: "#493824"))
                    .multilineTextAlignment(.center).padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: needsScroll) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in AccountQuestOverlayRowView(row: row, inMatch: inMatch) }
                    }
                }
                .padding(.horizontal, 16)
                Text(text(!inMatch ? "AccountProgress_MenuSnapshotNote"
                    : (status == "AccountProgress_JoinedMidMatch" ? status
                       : (rows.contains { $0.estimatedDelta != nil }
                          ? "AccountProgress_OverlayEstimateNote" : "AccountProgress_ConfirmedRefreshNote"))))
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#493824"))
                    .lineLimit(1).padding(.bottom, 12).frame(height: 28)
            }
        }
        .background(Image("flavor_text")
            .resizable(capInsets: EdgeInsets(top: 30, leading: 22, bottom: 24, trailing: 22))
            .interpolation(.high))
        .shadow(color: .black.opacity(0.45), radius: 5, x: 0, y: 3)
    }
}

struct AccountQuestOverlayRowView: View {
    let row: AccountQuestOverlayRow
    var inMatch = true
    private func text(_ key: String) -> String { String.localizedString(key, comment: "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title.hasPrefix("#") ? text("AccountProgress_QuestDetailsPending") : row.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "#302213"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)
            progressBar
            HStack(spacing: 4) {
                Text(text(row.categoryKey) + " · " + statusText)
                Spacer(minLength: 0)
                if row.estimatedDelta != nil {
                    Text(text("AccountProgress_Confirmed") + " \(row.confirmed)")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(hex: "#493824"))
            .lineLimit(1)
        }
        .padding(.vertical, 6)
        .frame(height: row.displayHeight)
        .accessibilityElement(children: .combine)
    }

    // Match ExperienceCounterView's composition: the scroll and gem cover
    // the straight ends of the track, independently of the progress mask.
    private var progressBar: some View {
        ZStack {
            ZStack(alignment: .leading) {
                Image("xp_empty_bar").resizable().interpolation(.high)
                GeometryReader { proxy in
                    Image("xp_filled_bar").resizable().interpolation(.high)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .mask(Rectangle().frame(width: proxy.size.width * CGFloat(row.fraction))
                            .frame(maxWidth: .infinity, alignment: .leading))
                }
            }
            .frame(height: 18)
            .padding(.leading, 12).padding(.trailing, 15)

            HStack(spacing: 0) {
                Image("xp_scroll_item").resizable().interpolation(.high)
                    .frame(width: 24, height: 25)
                Spacer(minLength: 0)
                Image("xp_gem").resizable().interpolation(.high)
                    .frame(width: 31, height: 22)
            }
            .accessibility(hidden: true)

            Text(row.quota > 0 ? "\(row.total) / \(row.quota)" : "\(row.confirmed) / —")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(.white).shadow(color: .black, radius: 1)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.2), value: row.fraction)
    }

    private var statusText: String {
        if row.isConfirmedComplete { return text("AccountProgress_QuestComplete") }
        if !inMatch && row.quota > 0 { return text("AccountProgress_Confirmed") }
        if row.isEstimatedComplete { return text("AccountProgress_EstimatedComplete") }
        if let delta = row.estimatedDelta { return text("AccountProgress_Estimate") + " +\(delta)" }
        return text(row.quota > 0 ? "AccountProgress_AfterMatch" : "AccountProgress_QuestDetailsPending")
    }
}
