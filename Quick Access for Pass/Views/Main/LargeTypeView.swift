import SwiftUI

struct LargeTypeView: View {
    static let largeTypeFontName = "Menlo"

    struct Layout: Sendable, Equatable {
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 24
        static let titleBarHeight: CGFloat = 28
        static let screenMargin: CGFloat = 48
        static let minimumTileSide: CGFloat = 128

        let columns: Int
        let tileSide: CGFloat

        var tileWidth: CGFloat { min(tileSide, 180) }
        var tileHeight: CGFloat { min(tileSide, 180) }
        var numberFontSize: CGFloat { max(14, tileHeight * 0.14) }
        var characterFontSize: CGFloat { max(28, tileHeight * 0.44) }
        var characterMaxHeight: CGFloat { tileHeight }

        func rows(for tileCount: Int) -> Int {
            max(1, Int(ceil(Double(tileCount) / Double(columns))))
        }

        func contentSize(for tileCount: Int) -> CGSize {
            let rows = rows(for: tileCount)
            let width = CGFloat(columns) * tileWidth + CGFloat(max(0, columns - 1)) * Self.spacing + Self.padding * 2
            let height = CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * Self.spacing + Self.padding * 2
            return CGSize(width: width, height: height)
        }

        static func bestFit(tileCount: Int, visibleFrame: CGRect) -> Layout {
            let availableWidth = max(320, visibleFrame.width - Self.screenMargin * 2)
            let availableHeight = max(220, visibleFrame.height - Self.screenMargin * 2 - Self.titleBarHeight)
            let singleRowTileWidth = (availableWidth - Self.padding * 2 - CGFloat(max(0, tileCount - 1)) * Self.spacing) / CGFloat(max(1, tileCount))
            let singleRowTileHeight = availableHeight - Self.padding * 2
            let singleRowTileSide = floor(min(singleRowTileWidth, singleRowTileHeight))

            if singleRowTileSide >= Self.minimumTileSide {
                return Layout(columns: tileCount, tileSide: singleRowTileSide)
            }

            var bestLayout: Layout?

            for columns in 1...max(1, tileCount) {
                let rows = Int(ceil(Double(tileCount) / Double(columns)))
                let maxTileWidth = (availableWidth - Self.padding * 2 - CGFloat(max(0, columns - 1)) * Self.spacing) / CGFloat(columns)
                let maxTileHeight = (availableHeight - Self.padding * 2 - CGFloat(max(0, rows - 1)) * Self.spacing) / CGFloat(rows)
                let tileSide = floor(min(maxTileWidth, maxTileHeight))
                guard tileSide >= Self.minimumTileSide else { continue }

                let candidate = Layout(columns: columns, tileSide: tileSide)
                if let currentBest = bestLayout {
                    if candidate.tileSide > currentBest.tileSide ||
                        (candidate.tileSide == currentBest.tileSide && candidate.rows(for: tileCount) < currentBest.rows(for: tileCount)) {
                        bestLayout = candidate
                    }
                } else {
                    bestLayout = candidate
                }
            }

            return bestLayout ?? Layout(columns: tileCount, tileSide: Self.minimumTileSide)
        }
    }

    let display: LargeTypeDisplay
    let layout: Layout
    let onClose: () -> Void

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: Layout.spacing) {
            ForEach(display.tiles) { tile in
                VStack(spacing: 10) {
                    Text(tile.character)
                        .font(.custom(Self.largeTypeFontName, size: layout.characterFontSize).weight(.bold))
                        .foregroundStyle(foregroundStyle(for: tile.characterClass))
                        .frame(maxHeight: layout.characterMaxHeight)

                    Text("\(tile.position)")
                        .font(.custom(Self.largeTypeFontName, size: layout.numberFontSize))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(width: layout.tileWidth, height: layout.tileHeight)
                .background(backgroundStyle(for: tile.parity), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            }
        }
        .padding(Layout.padding)
        .background(.regularMaterial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        String(
            localized: "Large Type, \(display.tiles.count) characters",
            comment: "VoiceOver label for the Large Type window — exposes character count but never the value itself."
        )
    }

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: Layout.spacing), count: layout.columns)    }

    private func foregroundStyle(for characterClass: LargeTypeDisplay.CharacterClass) -> AnyShapeStyle {
        switch characterClass {
        case .letter:
            AnyShapeStyle(.primary)
        case .digit:
            AnyShapeStyle(.blue)
        case .symbol:
            AnyShapeStyle(.orange)
        }
    }

    private func backgroundStyle(for parity: LargeTypeDisplay.Parity) -> AnyShapeStyle {
        switch parity {
        case .odd:
            AnyShapeStyle(.thinMaterial)
        case .even:
            AnyShapeStyle(.quaternary)
        }
    }
}
