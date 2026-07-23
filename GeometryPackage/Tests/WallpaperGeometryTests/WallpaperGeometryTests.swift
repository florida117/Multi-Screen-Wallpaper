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
