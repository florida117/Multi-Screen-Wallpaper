import XCTest
import CoreGraphics
@testable import WallpaperGeometry

final class WallpaperGeometryTests: XCTestCase {

    // MARK: evenFractions

    func testEvenFractions() {
        XCTAssertEqual(WallpaperGeometry.evenFractions(count: 0), [])
        XCTAssertEqual(WallpaperGeometry.evenFractions(count: 1), [])
        XCTAssertEqual(WallpaperGeometry.evenFractions(count: 2), [0.5])
        let three = WallpaperGeometry.evenFractions(count: 3)
        XCTAssertEqual(three.count, 2)
        XCTAssertEqual(three[0], 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(three[1], 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: proportionalFractions / defaultFractions

    func testProportionalFractionsMatchesEvenForEqualSpans() {
        let f = WallpaperGeometry.proportionalFractions(spans: [1000, 1000, 1000])
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[0], 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(f[1], 2.0 / 3.0, accuracy: 1e-9)
    }

    func testProportionalFractionsWeightsBySpan() {
        // 3440 + 2560 = 6000; the cut belongs at 3440/6000.
        let f = WallpaperGeometry.proportionalFractions(spans: [3440, 2560])
        XCTAssertEqual(f, [3440.0 / 6000.0])
    }

    func testProportionalFractionsAreAscending() {
        let f = WallpaperGeometry.proportionalFractions(spans: [1000, 3440, 2560, 800])
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f, f.sorted())
        XCTAssertTrue(f.allSatisfy { $0 > 0 && $0 < 1 })
    }

    func testProportionalFractionsDegenerateInputs() {
        XCTAssertEqual(WallpaperGeometry.proportionalFractions(spans: []), [])
        XCTAssertEqual(WallpaperGeometry.proportionalFractions(spans: [1920]), [])
        // A non-positive span cannot be weighted; fall back to an even split.
        XCTAssertEqual(WallpaperGeometry.proportionalFractions(spans: [1920, 0]), [0.5])
    }

    func testDefaultFractionsUsesWidthForRowAndHeightForColumn() {
        let row = [CGRect(x: 0, y: 0, width: 3440, height: 1440),
                   CGRect(x: 3440, y: 0, width: 2560, height: 1440)]
        XCTAssertEqual(WallpaperGeometry.defaultFractions(orderedFrames: row, arrangement: .row, axis: .horizontal),
                       [3440.0 / 6000.0])

        let column = [CGRect(x: 0, y: 1080, width: 1920, height: 1080),
                      CGRect(x: 0, y: 0, width: 1920, height: 2160)]
        XCTAssertEqual(WallpaperGeometry.defaultFractions(orderedFrames: column, arrangement: .column, axis: .vertical),
                       [1080.0 / 3240.0])
    }

    func testDefaultFractionsEmptyForGridAndSingleDisplay() {
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                      CGRect(x: 1920, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(WallpaperGeometry.defaultFractions(orderedFrames: frames, arrangement: .grid, axis: .horizontal), [])
        XCTAssertEqual(WallpaperGeometry.defaultFractions(orderedFrames: [frames[0]], arrangement: .row, axis: .horizontal), [])
    }

    /// The regression this whole change exists for: with displays of differing
    /// width, an even split makes each screen sample the source at a different
    /// rate, so the image visibly steps in scale at the seam.
    func testDefaultFractionsGiveEveryDisplayTheSameSamplingRate() {
        let frames = [CGRect(x: 0, y: 0, width: 3440, height: 1440),
                      CGRect(x: 3440, y: 0, width: 2560, height: 1440)]
        let extent = CGRect(x: 0, y: 0, width: 6000, height: 1600)

        /// Source pixels consumed per screen pixel, vertically, for each display.
        func samplingRates(cuts: [CGFloat]) -> [CGFloat] {
            (0..<2).map { i in
                let slice = WallpaperGeometry.sliceRect(in: extent, axis: .horizontal, cuts: cuts, index: i)
                let crop = WallpaperGeometry.centerCrop(slice, toAspect: frames[i].width / frames[i].height)
                return crop.height / frames[i].height
            }
        }

        let even = samplingRates(cuts: [0] + WallpaperGeometry.evenFractions(count: 2) + [1])
        XCTAssertNotEqual(even[0], even[1], accuracy: 0.01,
                          "an even split should NOT match here — that is the bug being fixed")

        let proportional = samplingRates(
            cuts: [0] + WallpaperGeometry.defaultFractions(orderedFrames: frames, arrangement: .row, axis: .horizontal) + [1])
        XCTAssertEqual(proportional[0], proportional[1], accuracy: 1e-9)
    }

    // MARK: visibleExtent / offset clamping

    func testVisibleExtentAtZoomOneIsTheWholeImage() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        XCTAssertEqual(WallpaperGeometry.visibleExtent(extent, zoom: 1, offset: .zero), extent)
        // Below 1 is treated as 1 rather than zooming out past the image.
        XCTAssertEqual(WallpaperGeometry.visibleExtent(extent, zoom: 0.5, offset: .zero), extent)
    }

    func testVisibleExtentAtZoomOneIgnoresOffset() {
        // Nothing to pan to when the whole image already fits.
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        XCTAssertEqual(WallpaperGeometry.visibleExtent(extent, zoom: 1, offset: CGSize(width: 0.4, height: 0.4)), extent)
    }

    func testVisibleExtentCentresWhenNotPanned() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        let v = WallpaperGeometry.visibleExtent(extent, zoom: 2, offset: .zero)
        XCTAssertEqual(v, CGRect(x: 1000, y: 250, width: 2000, height: 500))
    }

    func testVisibleExtentPansAndStaysInsideTheImage() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        // Max offset at 2x is (1 - 1/2)/2 = 0.25 of the extent.
        XCTAssertEqual(WallpaperGeometry.maxOffset(zoom: 2), 0.25, accuracy: 1e-9)

        let right = WallpaperGeometry.visibleExtent(extent, zoom: 2, offset: CGSize(width: 0.25, height: 0))
        XCTAssertEqual(right.maxX, extent.maxX, accuracy: 1e-6)

        // Beyond the limit clamps rather than running off the edge.
        let past = WallpaperGeometry.visibleExtent(extent, zoom: 2, offset: CGSize(width: 5, height: -5))
        XCTAssertEqual(past.maxX, extent.maxX, accuracy: 1e-6)
        XCTAssertEqual(past.minY, extent.minY, accuracy: 1e-6)
    }

    func testVisibleExtentAlwaysWithinExtent() {
        let extent = CGRect(x: 100, y: 50, width: 4000, height: 1000)
        for zoom in stride(from: 1.0 as CGFloat, through: 4.0, by: 0.25) {
            for dx in stride(from: -1.0 as CGFloat, through: 1.0, by: 0.2) {
                let v = WallpaperGeometry.visibleExtent(extent, zoom: zoom, offset: CGSize(width: dx, height: -dx))
                XCTAssertTrue(extent.contains(v.insetBy(dx: -1e-6, dy: -1e-6).intersection(extent)))
                XCTAssertGreaterThanOrEqual(v.minX, extent.minX - 1e-6)
                XCTAssertGreaterThanOrEqual(v.minY, extent.minY - 1e-6)
                XCTAssertLessThanOrEqual(v.maxX, extent.maxX + 1e-6)
                XCTAssertLessThanOrEqual(v.maxY, extent.maxY + 1e-6)
            }
        }
    }

    func testVisibleExtentPreservesAspectRatio() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        for zoom in [1.0, 1.5, 2.0, 3.7] as [CGFloat] {
            let v = WallpaperGeometry.visibleExtent(extent, zoom: zoom, offset: CGSize(width: 0.1, height: -0.05))
            XCTAssertEqual(v.width / v.height, extent.width / extent.height, accuracy: 1e-9)
        }
    }

    func testClampOffsetCollapsesToZeroAtZoomOne() {
        XCTAssertEqual(WallpaperGeometry.maxOffset(zoom: 1), 0)
        let c = WallpaperGeometry.clampOffset(CGSize(width: 0.9, height: -0.9), zoom: 1)
        XCTAssertEqual(c.width, 0)
        XCTAssertEqual(c.height, 0)
    }

    // MARK: analyzeLayout

    func testSingleDisplayIsRow() {
        let layout = WallpaperGeometry.analyzeLayout(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.order, [0])
    }

    func testHorizontalRowEqualDisplays() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let layout = WallpaperGeometry.analyzeLayout(frames: frames)
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.axis, .horizontal)
        XCTAssertEqual(layout.order, [0, 1])
    }

    func testRowSortedLeftToRightRegardlessOfInputOrder() {
        let frames = [
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),  // right, given first
            CGRect(x: 0, y: 0, width: 1920, height: 1080),     // left
        ]
        let layout = WallpaperGeometry.analyzeLayout(frames: frames)
        XCTAssertEqual(layout.arrangement, .row)
        XCTAssertEqual(layout.order, [1, 0])
    }

    func testRowWithMixedHeightsBottomAligned() {
        // 27" + 24" side by side, shorter fully within taller's vertical band.
        let frames = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: 2560, y: 0, width: 1920, height: 1080),
        ]
        let layout = WallpaperGeometry.analyzeLayout(frames: frames)
        XCTAssertEqual(layout.arrangement, .row)
    }

    func testVerticalColumn() {
        // Two displays stacked; top display has the larger maxY.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),      // bottom
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),   // top
        ]
        let layout = WallpaperGeometry.analyzeLayout(frames: frames)
        XCTAssertEqual(layout.arrangement, .column)
        XCTAssertEqual(layout.axis, .vertical)
        XCTAssertEqual(layout.order, [1, 0])  // top-to-bottom
    }

    func testGridLayout() {
        let frames = [
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),      // top-left
            CGRect(x: 1920, y: 1080, width: 1920, height: 1080),   // top-right
            CGRect(x: 0, y: 0, width: 1920, height: 1080),         // bottom-left
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),      // bottom-right
        ]
        let layout = WallpaperGeometry.analyzeLayout(frames: frames)
        XCTAssertEqual(layout.arrangement, .grid)
        // Reading order: top band left-to-right, then bottom band.
        XCTAssertEqual(layout.order, [0, 1, 2, 3])
    }

    // MARK: sliceRect

    func testSliceRectHorizontal() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        let cuts: [CGFloat] = [0, 0.25, 1]
        let s0 = WallpaperGeometry.sliceRect(in: extent, axis: .horizontal, cuts: cuts, index: 0)
        let s1 = WallpaperGeometry.sliceRect(in: extent, axis: .horizontal, cuts: cuts, index: 1)
        XCTAssertEqual(s0, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(s1, CGRect(x: 1000, y: 0, width: 3000, height: 1000))
    }

    func testSliceRectVerticalTopFirst() {
        let extent = CGRect(x: 0, y: 0, width: 1000, height: 4000)
        let cuts: [CGFloat] = [0, 0.25, 1]
        // Section 0 is the TOP of the image (highest Y).
        let top = WallpaperGeometry.sliceRect(in: extent, axis: .vertical, cuts: cuts, index: 0)
        let bottom = WallpaperGeometry.sliceRect(in: extent, axis: .vertical, cuts: cuts, index: 1)
        XCTAssertEqual(top, CGRect(x: 0, y: 3000, width: 1000, height: 1000))
        XCTAssertEqual(bottom, CGRect(x: 0, y: 0, width: 1000, height: 3000))
    }

    // MARK: centerCrop

    func testCenterCropTrimsWidthWhenSourceWider() {
        // Source 2:1, target 1:1 -> trim width, keep full height.
        let crop = WallpaperGeometry.centerCrop(CGRect(x: 0, y: 0, width: 200, height: 100), toAspect: 1)
        XCTAssertEqual(crop, CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    func testCenterCropTrimsHeightWhenSourceTaller() {
        // Source 1:2, target 1:1 -> trim height, keep full width.
        let crop = WallpaperGeometry.centerCrop(CGRect(x: 0, y: 0, width: 100, height: 200), toAspect: 1)
        XCTAssertEqual(crop, CGRect(x: 0, y: 50, width: 100, height: 100))
    }

    func testCenterCropMatchingAspectIsNoOp() {
        let rect = CGRect(x: 10, y: 20, width: 160, height: 90)
        let crop = WallpaperGeometry.centerCrop(rect, toAspect: 160.0 / 90.0)
        XCTAssertEqual(crop.width, rect.width, accuracy: 1e-6)
        XCTAssertEqual(crop.height, rect.height, accuracy: 1e-6)
    }

    // MARK: proportionalRect

    func testProportionalRectMapsGridCell() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let union = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let topLeft = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let mapped = WallpaperGeometry.proportionalRect(in: extent, screenFrame: topLeft, unionBox: union)
        XCTAssertEqual(mapped.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(mapped.width, 2000, accuracy: 1e-6)   // half of 4000
        XCTAssertEqual(mapped.height, 1000, accuracy: 1e-6)  // half of 2000
        XCTAssertEqual(mapped.minY, 1000, accuracy: 1e-6)    // top half (Y-up)
    }
}
