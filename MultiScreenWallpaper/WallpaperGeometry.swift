import CoreGraphics
import Foundation

// MARK: - Display arrangement model
//
// Pure, AppKit-free geometry used by both the wallpaper renderer and the
// interactive canvas. Keeping it dependency-free lets it be unit-tested
// directly (see the WallpaperGeometryTests SwiftPM package).

/// The axis along which a panorama is divided between displays.
public enum SplitAxis: Equatable {
    /// Displays sit in a left-to-right row; the image is divided by vertical cuts.
    case horizontal
    /// Displays are stacked top-to-bottom; the image is divided by horizontal cuts.
    case vertical
}

/// How the connected displays are physically arranged on the desk.
public enum DisplayArrangement: Equatable {
    /// A clean horizontal row — divide the image with draggable vertical split lines.
    case row
    /// A clean vertical column — divide the image with draggable horizontal split lines.
    case column
    /// Anything else (e.g. a 2×2 grid). Split lines don't apply; each display is
    /// mapped to the image region matching its physical position instead.
    case grid
}

/// The result of classifying a set of display frames.
public struct DisplayLayout: Equatable {
    public let arrangement: DisplayArrangement
    /// The dominant split axis. Meaningful for `.row`/`.column`; `.horizontal`
    /// as a placeholder for `.grid` (which doesn't use split lines).
    public let axis: SplitAxis
    /// Indices into the input `frames`, in span order (first = leftmost / topmost).
    public let order: [Int]

    public init(arrangement: DisplayArrangement, axis: SplitAxis, order: [Int]) {
        self.arrangement = arrangement
        self.axis = axis
        self.order = order
    }
}

public enum WallpaperGeometry {

    /// Evenly-spaced interior split fractions for `screens` displays (empty for 0/1).
    public static func evenFractions(count screens: Int) -> [CGFloat] {
        guard screens > 1 else { return [] }
        return (1..<screens).map { CGFloat($0) / CGFloat(screens) }
    }

    /// The bounding box that encloses every display frame.
    public static func unionBox(_ frames: [CGRect]) -> CGRect {
        guard !frames.isEmpty else { return .zero }
        let minX = frames.map(\.minX).min()!
        let minY = frames.map(\.minY).min()!
        let maxX = frames.map(\.maxX).max()!
        let maxY = frames.map(\.maxY).max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Classify how the given display frames are arranged (global coordinates, Y-up).
    ///
    /// A row is detected when the displays' widths tile horizontally while sharing a
    /// common vertical band; a column is the transpose. Anything else is a grid.
    public static func analyzeLayout(frames: [CGRect]) -> DisplayLayout {
        let indices = Array(frames.indices)
        guard frames.count > 1 else {
            return DisplayLayout(arrangement: .row, axis: .horizontal, order: indices)
        }

        let u = unionBox(frames)
        let sumW = frames.map(\.width).reduce(0, +)
        let sumH = frames.map(\.height).reduce(0, +)
        let maxW = frames.map(\.width).max()!
        let maxH = frames.map(\.height).max()!

        func approx(_ a: CGFloat, _ b: CGFloat, dim: CGFloat) -> Bool {
            abs(a - b) <= max(4.0, 0.05 * dim)
        }

        let tilesHorizontally = approx(u.width, sumW, dim: u.width)
        let sharesVertically  = approx(u.height, maxH, dim: u.height)
        let tilesVertically   = approx(u.height, sumH, dim: u.height)
        let sharesHorizontally = approx(u.width, maxW, dim: u.width)

        let isRow    = tilesHorizontally && sharesVertically
        let isColumn = tilesVertically && sharesHorizontally

        let leftToRight = indices.sorted { frames[$0].minX < frames[$1].minX }
        // Top of the image maps to the physically highest display (largest maxY).
        let topToBottom = indices.sorted { frames[$0].maxY > frames[$1].maxY }

        if isRow && !isColumn {
            return DisplayLayout(arrangement: .row, axis: .horizontal, order: leftToRight)
        }
        if isColumn && !isRow {
            return DisplayLayout(arrangement: .column, axis: .vertical, order: topToBottom)
        }
        if isRow && isColumn {
            return DisplayLayout(arrangement: .row, axis: .horizontal, order: leftToRight)
        }

        // Grid: order in reading order (top band first, left-to-right within a band).
        let readingOrder = indices.sorted {
            if abs(frames[$0].maxY - frames[$1].maxY) > max(4.0, 0.05 * u.height) {
                return frames[$0].maxY > frames[$1].maxY
            }
            return frames[$0].minX < frames[$1].minX
        }
        return DisplayLayout(arrangement: .grid, axis: .horizontal, order: readingOrder)
    }

    /// The source sub-rectangle of `extent` for section `index`, given sorted cut
    /// fractions `cuts` (which must start at 0 and end at 1).
    ///
    /// For `.horizontal` the cut varies left→right; for `.vertical` it varies
    /// top→down, so cut 0 corresponds to the top of the image (highest Y).
    public static func sliceRect(in extent: CGRect, axis: SplitAxis, cuts: [CGFloat], index i: Int) -> CGRect {
        switch axis {
        case .horizontal:
            let x0 = extent.minX + extent.width * cuts[i]
            let x1 = extent.minX + extent.width * cuts[i + 1]
            return CGRect(x: x0, y: extent.minY, width: x1 - x0, height: extent.height)
        case .vertical:
            let yTop = extent.maxY - extent.height * cuts[i]
            let yBot = extent.maxY - extent.height * cuts[i + 1]
            return CGRect(x: extent.minX, y: yBot, width: extent.width, height: yTop - yBot)
        }
    }

    /// Center-crop `rect` to `targetAspect` (width / height), trimming the longer axis.
    public static func centerCrop(_ rect: CGRect, toAspect targetAspect: CGFloat) -> CGRect {
        guard rect.width > 0, rect.height > 0, targetAspect > 0 else { return rect }
        let srcAspect = rect.width / rect.height
        if srcAspect > targetAspect {
            let w = rect.height * targetAspect
            return CGRect(x: rect.minX + (rect.width - w) / 2, y: rect.minY, width: w, height: rect.height)
        } else {
            let h = rect.width / targetAspect
            return CGRect(x: rect.minX, y: rect.minY + (rect.height - h) / 2, width: rect.width, height: h)
        }
    }

    /// The region of `extent` that corresponds to `screenFrame`'s physical position
    /// within `unionBox` — used to span an image across a grid of displays.
    public static func proportionalRect(in extent: CGRect, screenFrame f: CGRect, unionBox u: CGRect) -> CGRect {
        guard u.width > 0, u.height > 0 else { return extent }
        let nx = (f.minX - u.minX) / u.width
        let ny = (f.minY - u.minY) / u.height
        return CGRect(x: extent.minX + extent.width * nx,
                      y: extent.minY + extent.height * ny,
                      width:  extent.width * (f.width / u.width),
                      height: extent.height * (f.height / u.height))
    }
}
