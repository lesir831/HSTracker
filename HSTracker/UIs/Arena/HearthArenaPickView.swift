import SwiftUI

struct HearthArenaPickView: View {
    @ObservedObject var viewModel: HearthArenaPickViewModel
    @ObservedObject var arenasmith: ArenaPickHelperViewModel

    var body: some View {
        HearthArenaRatingRow(rows: viewModel.rows, statusKey: viewModel.statusKey,
            // The related-card panel starts at y=669, under the second score row.
            // Give that hover panel room while it is open.
            isVisible: viewModel.isVisible && !(arenasmith.isVisible && arenasmith.showBottom),
            alongsideArenasmith: arenasmith.isVisible && arenasmith.cardStats != nil && arenasmith.arenasmithScoreVisible)
    }
}

/// Shares the existing card-offer geometry. Does not intercept draft clicks.
struct HearthArenaRatingRow: View {
    let rows: [HearthArenaPickRating]
    let statusKey: String
    let isVisible: Bool
    let alongsideArenasmith: Bool
    static let optionsWidth: CGFloat = 1440 * 3.25 / 4.25
    static let columnWidth: CGFloat = optionsWidth * 0.782

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isVisible {
                HStack(spacing: 0) {
                    ForEach(rows) { row in
                        VStack(spacing: 2) {
                            Text("HearthArena").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(hex: "#E8C987"))
                            Text(statusKey == "HearthArena_Loading" ? "…" : row.scoreText)
                                .font(.system(size: 24, weight: .bold).monospacedDigit())
                                .foregroundColor(.white)
                            Text(String.localizedString(rowStatus(row), comment: ""))
                                .font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(width: 176, height: 76)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.84)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#B79B59"), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: Self.columnWidth)
                .offset(x: Self.optionsWidth * 0.108, y: alongsideArenasmith ? 667 : 595)
            }
        }
        .frame(width: 1440, height: 1080, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func rowStatus(_ row: HearthArenaPickRating) -> String {
        guard statusKey == "HearthArena_BaseScore" || statusKey == "HearthArena_Cached" else { return statusKey }
        if row.score == nil { return "HearthArena_NotListed" }
        if statusKey == "HearthArena_Cached" { return row.isPackage ? "HearthArena_CachedKeyCard" : statusKey }
        return row.isPackage ? "HearthArena_KeyCard" : statusKey
    }
}
