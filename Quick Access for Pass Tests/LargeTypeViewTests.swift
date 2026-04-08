import Testing
@testable import Quick_Access_for_Pass
import CoreGraphics

@Suite("LargeTypeView.Layout")
@MainActor
struct LargeTypeViewTests {
    // Locks the contentSize formula against regression. The tile-footprint
    // contract — that the view modifier stack renders each tile at exactly
    // tileSide × tileHeight — is visual and must be verified by eye.
    @Test func minimumTileSideIsOneHundredTwentyEightPoints() {
        #expect(LargeTypeView.Layout.minimumTileSide == 128)
    }

    @Test func contentSizeMatchesTileFootprintWithPaddingAndSpacing() {
        let layout = LargeTypeView.Layout(columns: 4, tileSide: 100)
        let size = layout.contentSize(for: 10)

        // 4 tiles * 100 + 3 gaps * spacing + 2 * outer padding
        let expectedWidth: CGFloat = 4 * 100
            + 3 * LargeTypeView.Layout.spacing
            + 2 * LargeTypeView.Layout.padding
        // 10 tiles / 4 columns = 3 rows -> 3 tiles * 100 + 2 gaps * spacing + 2 * padding
        let expectedHeight: CGFloat = 3 * 100
            + 2 * LargeTypeView.Layout.spacing
            + 2 * LargeTypeView.Layout.padding

        #expect(size.width == expectedWidth)
        #expect(size.height == expectedHeight)
    }

    @Test func rowsRoundsUpForPartialTrailingRow() {
        let layout = LargeTypeView.Layout(columns: 5, tileSide: 80)
        #expect(layout.rows(for: 11) == 3)
        #expect(layout.rows(for: 10) == 2)
        #expect(layout.rows(for: 1) == 1)
    }

    @Test func tileHeightIsCappedAtOneHundredEightyPoints() {
        let compactLayout = LargeTypeView.Layout(columns: 4, tileSide: 100)
        let oversizedLayout = LargeTypeView.Layout(columns: 1, tileSide: 420)

        #expect(compactLayout.tileHeight == 100)
        #expect(oversizedLayout.tileHeight == 180)
    }

    @Test func contentSizeUsesCappedTileHeight() {
        let layout = LargeTypeView.Layout(columns: 1, tileSide: 420)
        let size = layout.contentSize(for: 2)

        let expectedHeight: CGFloat = 2 * 180
            + LargeTypeView.Layout.spacing
            + 2 * LargeTypeView.Layout.padding

        #expect(size.height == expectedHeight)
    }

    @Test func characterFontSizeUsesCappedTileHeight() {
        let compactLayout = LargeTypeView.Layout(columns: 4, tileSide: 100)
        let oversizedLayout = LargeTypeView.Layout(columns: 1, tileSide: 420)

        #expect(compactLayout.characterFontSize == 44)
        #expect(oversizedLayout.characterFontSize == 79.2)
    }

    @Test func tileWidthIsCappedAtOneHundredEightyPoints() {
        let compactLayout = LargeTypeView.Layout(columns: 4, tileSide: 100)
        let oversizedLayout = LargeTypeView.Layout(columns: 1, tileSide: 420)

        #expect(compactLayout.tileWidth == 100)
        #expect(oversizedLayout.tileWidth == 180)
    }

    @Test func contentSizeUsesCappedTileWidth() {
        let layout = LargeTypeView.Layout(columns: 2, tileSide: 420)
        let size = layout.contentSize(for: 2)

        let expectedWidth: CGFloat = 2 * 180
            + LargeTypeView.Layout.spacing
            + 2 * LargeTypeView.Layout.padding

        #expect(size.width == expectedWidth)
    }

    @Test func bestFitPrefersSingleRowWhenItFits() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let layout = LargeTypeView.Layout.bestFit(tileCount: 4, visibleFrame: visibleFrame)

        #expect(layout.columns == 4)
        #expect(layout.rows(for: 4) == 1)
    }

    @Test func bestFitPrefersSingleRowWhenWideScreenCanFitCappedTiles() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1800, height: 800)

        let layout = LargeTypeView.Layout.bestFit(tileCount: 8, visibleFrame: visibleFrame)

        #expect(layout.columns == 8)
        #expect(layout.rows(for: 8) == 1)
        #expect(layout.tileWidth == 180)
    }

    @Test func bestFitWrapsWhenSingleRowWouldDropBelowMinimumTileSide() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let layout = LargeTypeView.Layout.bestFit(tileCount: 8, visibleFrame: visibleFrame)

        #expect(layout.rows(for: 8) > 1)
        #expect(layout.tileWidth >= LargeTypeView.Layout.minimumTileSide)
    }
}
