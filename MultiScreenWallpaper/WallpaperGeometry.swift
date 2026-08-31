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

    /// Interior split fractions that give each display a share of the image
    /// proportional to its own extent along the split axis.
    ///
    /// An even split hands every display the same slice regardless of how wide it
    /// is, so a narrow screen next to a wide one has to magnify its slice further
    /// to fill itself — and the image steps in scale at the seam. Weighting by
    /// display size makes every screen sample the source at the same rate, which
    /// is what keeps a panorama continuous across the join.
    ///
    /// Falls back to an even split if any span is non-positive.
    public static func proportionalFractions(spans: [CGFloat]) -> [CGFloat] {
        guard spans.count > 1 else { return [] }
        guard spans.allSatisfy({ $0 > 0 }) else { return evenFractions(count: spans.count) }
        let total = spans.reduce(0, +)
        var running: CGFloat = 0
        return spans.dropLast().map { span in
            running += span
            return running / total
        }
    }

    /// The split fractions a layout should start from.
    ///
    /// `orderedFrames` must already be in span order (as `DisplayLayout.order`
    /// gives them). Grids have no split lines, so they get none.
    public static func defaultFractions(orderedFrames: [CGRect],
                                        arrangement: DisplayArrangement,
                                        axis: SplitAxis) -> [CGFloat] {
        guard arrangement != .grid, orderedFrames.count > 1 else { return [] }
        let spans = orderedFrames.map { axis == .horizontal ? $0.width : $0.height }
        return proportionalFractions(spans: spans)
    }

    // MARK: - Zoom and pan

    /// The largest offset magnitude that keeps the zoomed window inside the image,
    /// as a fraction of the full extent. Zero at `zoom <= 1`, where the whole image
    /// is already visible and there is nothing to pan to.
    public static func maxOffset(zoom: CGFloat) -> CGFloat {
        let z = max(1, zoom)
        return (1 - 1 / z) / 2
    }

    /// Clamp a pan offset to the range that keeps the image covering every display.
    public static func clampOffset(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let m = maxOffset(zoom: zoom)
        return CGSize(width:  min(max(offset.width,  -m), m),
                      height: min(max(offset.height, -m), m))
    }

    /// The sub-rectangle of `extent` that remains visible at `zoom`, panned by
    /// `offset` (a fraction of the full extent, measured from the centre).
    ///
    /// The result is always fully inside `extent`, so panning can never expose an
    /// edge: every display is guaranteed real image rather than blank margin.
    /// `zoom` of 1 with a zero offset returns `extent` unchanged, which is what
    /// makes the un-zoomed path identical to the original behaviour.
    public static func visibleExtent(_ extent: CGRect, zoom: CGFloat, offset: CGSize) -> CGRect {
        guard extent.width > 0, extent.height > 0 else { return extent }
        let z = max(1, zoom)
        let w = extent.width / z, h = extent.height / z
        let slackX = extent.width - w, slackY = extent.height - h
        let clamped = clampOffset(offset, zoom: z)
        // Offset is measured from the centred position, in units of the full extent.
        let x = extent.minX + slackX / 2 + clamped.width * extent.width
        let y = extent.minY + slackY / 2 + clamped.height * extent.height
        return CGRect(x: min(max(x, extent.minX), extent.minX + slackX),
                      y: min(max(y, extent.minY), extent.minY + slackY),
                      width: w, height: h)
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
        alignedCrop(rect, toAspect: targetAspect, alignment: CGPoint(x: 0.5, y: 0.5))
    }

    /// Crop `rect` to `targetAspect`, sliding the crop along whichever axis gets
    /// trimmed. `alignment` runs 0...1 per axis — 0 is left/bottom, 1 is right/top,
    /// and 0.5 is centred, which reproduces `centerCrop` exactly.
    ///
    /// Only one axis is ever trimmed, so only the corresponding component of
    /// `alignment` has any effect.
    public static func alignedCrop(_ rect: CGRect, toAspect targetAspect: CGFloat,
                                   alignment: CGPoint) -> CGRect {
        guard rect.width > 0, rect.height > 0, targetAspect > 0 else { return rect }
        func unit(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

        let srcAspect = rect.width / rect.height
        if srcAspect > targetAspect {
            let w = rect.height * targetAspect
            return CGRect(x: rect.minX + (rect.width - w) * unit(alignment.x), y: rect.minY,
                          width: w, height: rect.height)
        } else {
            let h = rect.width / targetAspect
            return CGRect(x: rect.minX, y: rect.minY + (rect.height - h) * unit(alignment.y),
                          width: rect.width, height: h)
        }
    }

    /// Crop `rect` to `targetAspect`, positioning it so that every display shares
    /// one linear mapping from physical desk space to image space. A display
    /// mounted higher than its neighbour therefore shows a correspondingly higher
    /// band of the image, and a feature crossing the seam stays continuous.
    ///
    /// Only the axis the split lines do *not* control is taken from the
    /// arrangement. In a row the splits already decide horizontal placement, so
    /// letting the arrangement move the crop horizontally too would fight them;
    /// only the vertical follows the desk. A column is the transpose. Grids are
    /// already positioned by `proportionalRect`, so they crop centred.
    ///
    /// Note this cannot be expressed as a fixed 0...1 alignment computed from the
    /// frames alone: each display has a different amount of slack between its
    /// slice and its crop, so the same fraction means a different offset on each.
    /// The mapping has to be built from the crop size, which is why this returns a
    /// rectangle rather than an alignment.
    ///
    /// Uniformly aligned displays reduce to the centre crop exactly, so this only
    /// moves anything for arrangements that really are staggered.
    public static func arrangedCrop(_ rect: CGRect, toAspect targetAspect: CGFloat,
                                    frame: CGRect, union: CGRect,
                                    arrangement: DisplayArrangement) -> CGRect {
        guard rect.width > 0, rect.height > 0, targetAspect > 0 else { return rect }
        let centred = centerCrop(rect, toAspect: targetAspect)
        guard arrangement != .grid else { return centred }

        let srcAspect = rect.width / rect.height
        switch arrangement {
        case .row:
            // The vertical is free only when height is what gets trimmed.
            guard srcAspect <= targetAspect, frame.height > 0, union.height > 0 else { return centred }
            let cropH = centred.height
            // Image units consumed per point of physical height. Equal across
            // displays when the splits are proportional, which is what makes the
            // shared mapping continuous rather than merely ordered.
            let rate = cropH / frame.height
            let bandMinY = rect.minY + (rect.height - rate * union.height) / 2
            let y = bandMinY + rate * (frame.minY - union.minY)
            return CGRect(x: centred.minX,
                          y: min(max(y, rect.minY), rect.maxY - cropH),
                          width: centred.width, height: cropH)

        case .column:
            guard srcAspect >= targetAspect, frame.width > 0, union.width > 0 else { return centred }
            let cropW = centred.width
            let rate = cropW / frame.width
            let bandMinX = rect.minX + (rect.width - rate * union.width) / 2
            let x = bandMinX + rate * (frame.minX - union.minX)
            return CGRect(x: min(max(x, rect.minX), rect.maxX - cropW),
                          y: centred.minY,
                          width: cropW, height: centred.height)

        case .grid:
            return centred
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
