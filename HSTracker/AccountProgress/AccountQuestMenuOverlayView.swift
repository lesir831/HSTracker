import SwiftUI

/// Observe quest availability here rather than taking a stale Boolean from
/// RootOverlayView, whose model does not forward its children's publishers.
struct AccountQuestExperienceEntryView: View {
    @ObservedObject var quests: AccountQuestOverlayViewModel
    let experience: ExperienceCounterViewModel
    let canvasWidth: CGFloat
    let canvasScale: CGFloat

    var body: some View {
        ExperienceCounterView(viewModel: experience, canvasWidth: canvasWidth,
                              canvasScale: canvasScale, canOpenQuests: quests.menuAvailable,
                              onToggleQuests: { quests.toggleMenu() })
    }
}

struct AccountQuestMenuOverlayView: View {
    @ObservedObject var viewModel: AccountQuestOverlayViewModel
    let canvasWidth: CGFloat
    let canvasSize: CGSize

    private var panelFrame: CGRect {
        AccountQuestOverlayLayout.panelFrame(header: ExperienceCounterView.visualFrame(canvasWidth: canvasWidth),
            contentHeight: viewModel.rows.reduce(0) { $0 + $1.displayHeight })
    }
    private var pixelFrame: CGRect {
        let scale = canvasSize.height / 1080
        return CGRect(x: panelFrame.minX * scale, y: panelFrame.minY * scale,
                      width: panelFrame.width * scale, height: panelFrame.height * scale)
    }
    private var needsScroll: Bool {
        viewModel.rows.reduce(0) { $0 + $1.displayHeight }
            > panelFrame.height - AccountQuestOverlayLayout.panelChromeHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.menuExpanded {
                AccountQuestOverlayPanel(rows: viewModel.rows, status: viewModel.status,
                                         inMatch: false, needsScroll: needsScroll)
                    .frame(width: panelFrame.width, height: panelFrame.height)
                    .offset(x: panelFrame.minX, y: panelFrame.minY)
                    .allowsHitTesting(needsScroll)
                    .preference(key: InteractiveRegionPreferenceKey.self,
                                value: needsScroll ? [pixelFrame] : [])
                    .preference(key: HoverRegionPreferenceKey.self,
                                value: [HoverRegion(id: HoverRegionID.accountQuests, rect: pixelFrame)])
            }
        }
        .frame(width: canvasWidth, height: 1080, alignment: .topLeading)
    }
}
