import AppKit
import SwiftUI

// MARK: - NSViewRepresentable bridge

struct CanvasView: NSViewRepresentable {
    @ObservedObject var manager: WallpaperManager

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(manager: manager)
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.manager = manager
        nsView.needsDisplay = true
        // Zoom may have crossed the threshold where the image becomes draggable,
        // which changes whether the canvas offers a grab cursor.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Interactive canvas view

final class CanvasNSView: NSView {
    var manager: WallpaperManager? { didSet { structureChanged() } }

    private var draggingIndex: Int? = nil
    private var selectedIndex: Int? = nil
    /// Last cursor position during an image-pan drag; nil when not panning.
    private var panAnchor: NSPoint? = nil
    private let minGap: CGFloat = 0.05
    private let hitThreshold: CGFloat = 16

    // Accessibility children, rebuilt only when the *structure* changes (display
    // count, arrangement, names). Rebuilding on every value change would destroy
    // the element VoiceOver is focused on mid-adjustment.
    private var a11ySections: [SectionAccessibilityElement] = []
    private var a11ySplits: [SplitLineAccessibilityElement] = []
    private var a11yStructure: A11yStructure? = nil

    // The source NSImage is backed by an NSCIImageRep, so drawing it re-renders
    // the full-resolution CIImage through Core Image every single time — and draw()
    // runs on every drag frame. Cache a flat raster at the size actually blitted.
    private var cachedPreview: NSImage?
    private weak var cachedPreviewSource: NSImage?
    private var cachedPreviewSize: NSSize = .zero
    private var cachedPreviewScale: CGFloat = 0

    private struct A11yStructure: Equatable {
        let arrangement: DisplayArrangement
        let names: [String]
        let splitCount: Int
    }

    init(manager: WallpaperManager) {
        self.manager = manager
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        registerForDraggedTypes([.fileURL])
        focusRingType = .exterior
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Contrast / transparency preferences affect how the overlays are drawn.
        Accessibility.observeDisplayOptions(self, selector: #selector(displayOptionsChanged))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Accessibility.stopObservingDisplayOptions(self)
    }

    // Redraw when displays are reconfigured (e.g. a screen is rotated) so the
    // per-section crop preview reflects each screen's current aspect ratio.
    @objc private func screensChanged() { structureChanged() }

    @objc private func displayOptionsChanged() { needsDisplay = true }

    /// The set of accessibility elements may no longer match the UI.
    private func structureChanged() {
        needsDisplay = true
        guard rebuildAccessibilityChildrenIfNeeded() else { return }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Give Full Keyboard Access users something to act on immediately rather
        // than requiring a blind first arrow press to reveal a selection.
        if selectedIndex == nil, let mgr = mgr(supportsSplits: true), !mgr.splitFractions.isEmpty {
            selectedIndex = 0
        }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // System background when empty (respects light/dark); black once an image
        // is loaded for clean letterboxing.
        let background: NSColor = manager?.sourceImage != nil ? .black : .windowBackgroundColor
        background.setFill()
        bounds.fill()

        guard let image = manager?.sourceImage else {
            drawDropHint()
            drawCanvasFocusRing()
            return
        }

        let drawRect = aspectFit(size: image.size, in: bounds)
        drawPreview(of: image, in: drawRect)

        let sections = sectionBands(in: drawRect)
        drawCropDimming(sections)

        switch manager?.layout.arrangement ?? .row {
        case .row, .column:
            drawSplitLines(in: drawRect)
        case .grid:
            drawGridOutlines(sections)
        }

        drawSectionLabels(sections)
        drawCanvasFocusRing()
    }

    /// A focus ring around the whole canvas so keyboard users can see where focus
    /// is, even before a split line is selected. Drawn inside the bounds because
    /// the canvas is flush with its container.
    private func drawCanvasFocusRing() {
        guard window?.firstResponder === self, window?.isKeyWindow == true else { return }
        let ring = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 3
        NSColor.keyboardFocusIndicatorColor.setStroke()
        ring.stroke()
    }

    /// Draw the part of the image the current zoom and pan leave visible, filling
    /// `drawRect`. At fit this is the whole image, exactly as before framing existed.
    private func drawPreview(of image: NSImage, in drawRect: NSRect) {
        let zoom = manager?.zoom ?? 1
        let offset = manager?.offset ?? .zero
        let raster = preview(of: image, at: previewRasterSize(for: drawRect.size, zoom: zoom))

        // `preview` falls back to the source image if it cannot make a bitmap, so
        // take the size from what came back rather than what was asked for.
        let base = raster.size
        let unit = WallpaperGeometry.visibleExtent(CGRect(x: 0, y: 0, width: 1, height: 1),
                                                   zoom: zoom, offset: offset)
        let src = NSRect(x: unit.minX * base.width, y: unit.minY * base.height,
                         width: unit.width * base.width, height: unit.height * base.height)
        raster.draw(in: drawRect, from: src, operation: .copy, fraction: 1.0)
    }

    /// How large to rasterise the image behind the preview. Zooming in puts more
    /// source pixels behind the same on-screen rectangle, so the raster grows with
    /// the zoom — capped, so a deep zoom in a large window cannot allocate an
    /// unbounded bitmap. Panning does not change this size, which is what keeps a
    /// pan drag on the cached raster instead of re-rendering every frame.
    private func previewRasterSize(for fitSize: NSSize, zoom: CGFloat) -> NSSize {
        let maxDimension: CGFloat = 4096
        let target = NSSize(width: fitSize.width * zoom, height: fitSize.height * zoom)
        let overshoot = max(target.width, target.height) / maxDimension
        guard overshoot > 1 else { return target }
        return NSSize(width: target.width / overshoot, height: target.height / overshoot)
    }

    /// A rasterised copy of `image` at `size`, rebuilt only when the image, the
    /// draw size, or the backing scale changes. Falls back to the original image
    /// if a bitmap cannot be created.
    private func preview(of image: NSImage, at size: NSSize) -> NSImage {
        let scale = window?.backingScaleFactor ?? 1
        if let cached = cachedPreview, cachedPreviewSource === image,
           cachedPreviewScale == scale,
           abs(cachedPreviewSize.width - size.width) < 0.5,
           abs(cachedPreviewSize.height - size.height) < 0.5 {
            return cached
        }

        let rect = NSRect(origin: .zero, size: size)
        guard size.width >= 1, size.height >= 1,
              let rep = bitmapImageRepForCachingDisplay(in: rect) else { return image }

        // The rep's initial contents are undefined, so bail rather than cache
        // uninitialised pixels if no context can be made for it.
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        // Matches the view's backing store, so the raster keeps the display's
        // scale and colour space rather than being flattened to device RGB.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let raster = NSImage(size: size)
        raster.addRepresentation(rep)
        cachedPreview = raster
        cachedPreviewSource = image
        cachedPreviewSize = size
        cachedPreviewScale = scale
        return raster
    }

    private func drawDropHint() {
        let text = "Open an image with ⌘O  or  drag and drop here" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Accessibility.font(forTextStyle: .body),
            // tertiaryLabelColor is deliberately low-contrast; this hint is the
            // only content on screen, so it uses a colour that stays readable.
            .foregroundColor: Accessibility.increaseContrast ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2),
                  withAttributes: attrs)
    }

    // MARK: Section geometry

    private struct Section {
        let rect: NSRect
        let aspect: CGFloat
        let name: String
    }

    /// Display name for section `i`, falling back to a positional name when the
    /// split count temporarily outruns the known displays.
    private func sectionName(_ i: Int) -> String {
        guard let mgr = manager, i < mgr.slots.count else { return "Screen \(i + 1)" }
        return mgr.slots[i].name
    }

    private func sectionCount(_ mgr: WallpaperManager) -> Int {
        mgr.layout.arrangement == .grid ? mgr.slots.count : mgr.splitFractions.count + 1
    }

    /// The on-canvas rectangle, target aspect, and label for each display's slice.
    private func sectionBands(in drawRect: NSRect) -> [Section] {
        guard let mgr = manager else { return [] }
        let slots = mgr.slots

        func aspect(_ i: Int) -> CGFloat { i < slots.count ? slots[i].aspect : drawRect.width / drawRect.height }

        switch mgr.layout.arrangement {
        case .row:
            let cuts: [CGFloat] = [0] + mgr.splitFractions + [1]
            return (0..<cuts.count - 1).map { i in
                let xL = drawRect.minX + drawRect.width * cuts[i]
                let xR = drawRect.minX + drawRect.width * cuts[i + 1]
                return Section(rect: NSRect(x: xL, y: drawRect.minY, width: xR - xL, height: drawRect.height),
                               aspect: aspect(i), name: sectionName(i))
            }
        case .column:
            let cuts: [CGFloat] = [0] + mgr.splitFractions + [1]
            return (0..<cuts.count - 1).map { i in
                let yTop = drawRect.maxY - drawRect.height * cuts[i]      // cut 0 = top of image
                let yBot = drawRect.maxY - drawRect.height * cuts[i + 1]
                return Section(rect: NSRect(x: drawRect.minX, y: yBot, width: drawRect.width, height: yTop - yBot),
                               aspect: aspect(i), name: sectionName(i))
            }
        case .grid:
            let u = mgr.unionBox
            guard u.width > 0, u.height > 0 else { return [] }
            return slots.enumerated().map { (i, slot) in
                let f = slot.frame
                let nx = (f.minX - u.minX) / u.width, ny = (f.minY - u.minY) / u.height
                let rect = NSRect(x: drawRect.minX + nx * drawRect.width,
                                  y: drawRect.minY + ny * drawRect.height,
                                  width:  (f.width / u.width) * drawRect.width,
                                  height: (f.height / u.height) * drawRect.height)
                return Section(rect: rect, aspect: slot.aspect, name: sectionName(i))
            }
        }
    }

    /// Dim the parts of each section that will be cropped away, so the preview
    /// shows exactly what lands on each display (mirrors WallpaperGeometry.centerCrop).
    private func drawCropDimming(_ sections: [Section]) {
        // Translucent dimming reads as a subtle veil; with reduced transparency or
        // increased contrast the trimmed area needs to be unmistakably excluded.
        let alpha: CGFloat = Accessibility.prefersOpaqueOverlays ? 0.85 : 0.55
        NSColor.black.withAlphaComponent(alpha).setFill()
        for s in sections {
            let band = s.rect
            let kept = WallpaperGeometry.centerCrop(band, toAspect: s.aspect)
            if kept.width < band.width - 0.5 {
                NSRect(x: band.minX, y: band.minY, width: kept.minX - band.minX, height: band.height).fill()
                NSRect(x: kept.maxX, y: band.minY, width: band.maxX - kept.maxX, height: band.height).fill()
            } else if kept.height < band.height - 0.5 {
                NSRect(x: band.minX, y: band.minY, width: band.width, height: kept.minY - band.minY).fill()
                NSRect(x: band.minX, y: kept.maxY, width: band.width, height: band.maxY - kept.maxY).fill()
            }
        }
    }

    private func drawSplitLines(in drawRect: NSRect) {
        guard let mgr = manager else { return }
        let axis = mgr.layout.axis
        let focused = (window?.firstResponder === self)
        let handleSize: CGFloat = Accessibility.increaseContrast ? 26 : 22

        for (i, fraction) in mgr.splitFractions.enumerated() {
            let (a, b): (NSPoint, NSPoint)   // line endpoints
            let handleCenter: NSPoint
            switch axis {
            case .horizontal:
                let x = drawRect.minX + drawRect.width * fraction
                a = NSPoint(x: x, y: drawRect.minY); b = NSPoint(x: x, y: drawRect.maxY)
                handleCenter = NSPoint(x: x, y: drawRect.midY)
            case .vertical:
                let y = drawRect.maxY - drawRect.height * fraction
                a = NSPoint(x: drawRect.minX, y: y); b = NSPoint(x: drawRect.maxX, y: y)
                handleCenter = NSPoint(x: drawRect.midX, y: y)
            }

            drawSplitLine(from: a, to: b)

            let handleRect = NSRect(x: handleCenter.x - handleSize / 2, y: handleCenter.y - handleSize / 2,
                                    width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            let border = NSBezierPath(ovalIn: handleRect)
            border.lineWidth = Accessibility.increaseContrast ? 3 : 2
            (Accessibility.increaseContrast ? NSColor.black : NSColor.systemBlue).setStroke()
            border.stroke()

            if i == selectedIndex {
                // A filled centre marks the selected handle by shape rather than
                // colour alone, so selection survives any colour-vision setting.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: handleRect.insetBy(dx: handleSize * 0.32, dy: handleSize * 0.32)).fill()

                if focused {
                    let ring = NSBezierPath(ovalIn: handleRect.insetBy(dx: -4, dy: -4))
                    ring.lineWidth = 3
                    NSColor.keyboardFocusIndicatorColor.setStroke()
                    ring.stroke()
                }
            }
        }
    }

    private func drawSplitLine(from a: NSPoint, to b: NSPoint) {
        let highContrast = Accessibility.increaseContrast
        let dash: [CGFloat] = highContrast ? [] : [8, 4]
        let width: CGFloat = highContrast ? 3 : 2

        func stroke(width: CGFloat, color: NSColor) {
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            path.lineWidth = width
            if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
            color.setStroke()
            path.stroke()
        }

        // A wider dark stroke underneath outlines the line on every side, so it
        // stays visible over light imagery as well as dark.
        stroke(width: width + 2, color: .black.withAlphaComponent(highContrast ? 1.0 : 0.55))
        stroke(width: width, color: .white.withAlphaComponent(highContrast ? 1.0 : 0.95))
    }

    private func drawGridOutlines(_ sections: [Section]) {
        let highContrast = Accessibility.increaseContrast
        for s in sections {
            let rect = s.rect.insetBy(dx: 1, dy: 1)
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = highContrast ? 5 : 4
            if !highContrast { outline.setLineDash([8, 4], count: 2, phase: 0) }
            NSColor.black.withAlphaComponent(highContrast ? 1.0 : 0.55).setStroke()
            outline.stroke()

            let path = NSBezierPath(rect: rect)
            path.lineWidth = highContrast ? 3 : 2
            if !highContrast { path.setLineDash([8, 4], count: 2, phase: 0) }
            NSColor.white.withAlphaComponent(highContrast ? 1.0 : 0.9).setStroke()
            path.stroke()
        }
    }

    private func drawSectionLabels(_ sections: [Section]) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Accessibility.font(forTextStyle: .caption1, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        // A solid chip behind the label guarantees legible contrast over any
        // image, which a drop shadow alone cannot.
        let chipColor = NSColor.black.withAlphaComponent(Accessibility.prefersOpaqueOverlays ? 1.0 : 0.7)

        for s in sections {
            let label = s.name as NSString
            let sz = label.size(withAttributes: attrs)
            let origin = NSPoint(x: s.rect.midX - sz.width / 2, y: s.rect.minY + 10)
            let chip = NSRect(x: origin.x - 6, y: origin.y - 3, width: sz.width + 12, height: sz.height + 6)

            chipColor.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            if Accessibility.increaseContrast {
                let border = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
                border.lineWidth = 1
                NSColor.white.setStroke()
                border.stroke()
            }
            label.draw(at: origin, withAttributes: attrs)
        }
    }

    // MARK: Mouse — drag split lines

    override func mouseDown(with event: NSEvent) {
        // Take focus on any click, including grid layouts, so the canvas is a
        // predictable keyboard destination regardless of arrangement.
        window?.makeFirstResponder(self)

        guard let mgr = manager, mgr.sourceImage != nil, let drawRect = imageDrawRect() else { return }
        let pt = convert(event.locationInWindow, from: nil)
        draggingIndex = nil
        panAnchor = nil

        // A split handle takes priority; grids have none to hit.
        if mgr.layout.arrangement != .grid {
            for (i, fraction) in mgr.splitFractions.enumerated()
            where abs(perpendicularDistance(of: pt, fraction: fraction, axis: mgr.layout.axis, in: drawRect)) < hitThreshold {
                draggingIndex = i
                selectedIndex = i
                break
            }
        }

        // Anywhere else drags the image itself — but only when zoomed in, since at
        // fit there is nowhere to pan to and the drag would do nothing.
        if draggingIndex == nil, mgr.canPan {
            panAnchor = pt
            NSCursor.closedHand.push()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mgr = manager, let drawRect = imageDrawRect() else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if let idx = draggingIndex {
            setFraction(index: idx, to: fractionValue(of: pt, axis: mgr.layout.axis, in: drawRect))
            return
        }

        guard let anchor = panAnchor, drawRect.width > 0, drawRect.height > 0 else { return }
        // Dragging the image to the right reveals what lies to its left, so the
        // visible window travels opposite to the cursor.
        mgr.pan(dx: -(pt.x - anchor.x) / drawRect.width,
                dy: -(pt.y - anchor.y) / drawRect.height)
        panAnchor = pt
    }

    override func mouseUp(with event: NSEvent) {
        if let idx = draggingIndex { announceSplit(index: idx) }
        if panAnchor != nil {
            NSCursor.pop()
            panAnchor = nil
            // Announced once the drag settles rather than on every frame.
            if let mgr = manager { Accessibility.announce(mgr.framingSummary) }
        }
        draggingIndex = nil
    }

    // MARK: Pinch to zoom

    override func magnify(with event: NSEvent) {
        guard let mgr = manager, mgr.sourceImage != nil else { return }
        mgr.zoomBy(1 + event.magnification)
        if event.phase == .ended || event.phase == .cancelled {
            Accessibility.announce(mgr.framingSummary)
        }
        needsDisplay = true
    }

    /// An open hand over the canvas signals that the image itself can be dragged.
    /// Only offered when zoomed in, so it never promises an interaction that would
    /// do nothing.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard manager?.canPan == true else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: Keyboard — nudge / select split lines

    override func keyDown(with event: NSEvent) {
        // Tab must keep moving through the key view loop, so Full Keyboard Access
        // users are never trapped inside the canvas.
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        if event.keyCode == 53, selectedIndex != nil {   // escape clears the selection
            selectedIndex = nil
            needsDisplay = true
            return
        }

        guard let mgr = mgr(supportsSplits: true), !mgr.splitFractions.isEmpty else {
            super.keyDown(with: event); return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.05 : 0.01
        let axis = mgr.layout.axis

        // Arrows along the split axis move the selected line; across it change selection.
        switch Int(event.keyCode) {
        case 123: // left
            axis == .horizontal ? nudge(by: -step) : changeSelection(-1)
        case 124: // right
            axis == .horizontal ? nudge(by:  step) : changeSelection(1)
        case 126: // up
            axis == .vertical   ? nudge(by: -step) : changeSelection(-1)
        case 125: // down
            axis == .vertical   ? nudge(by:  step) : changeSelection(1)
        case 115: // home
            moveSelectedToLimit(towardStart: true)
        case 119: // end
            moveSelectedToLimit(towardStart: false)
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(by delta: CGFloat) {
        guard let mgr = manager else { return }
        if selectedIndex == nil { selectedIndex = 0 }
        guard let idx = selectedIndex, idx < mgr.splitFractions.count else { return }
        setFraction(index: idx, to: mgr.splitFractions[idx] + delta)
        announceSplit(index: idx)
    }

    /// Push the selected split as far as it will go, which is otherwise dozens of
    /// arrow presses away.
    private func moveSelectedToLimit(towardStart: Bool) {
        guard let mgr = manager else { return }
        if selectedIndex == nil { selectedIndex = 0 }
        guard let idx = selectedIndex, idx < mgr.splitFractions.count else { return }
        setFraction(index: idx, to: towardStart ? 0 : 1)
        announceSplit(index: idx)
    }

    private func changeSelection(_ delta: Int) {
        guard let mgr = manager, !mgr.splitFractions.isEmpty else { return }
        let count = mgr.splitFractions.count
        let current = selectedIndex ?? 0
        let next = max(0, min(count - 1, current + delta))
        selectedIndex = next
        needsDisplay = true
        announceSplit(index: next)
    }

    /// Speak the split's identity and position after a keyboard or mouse change.
    /// VoiceOver only narrates its own increment/decrement automatically.
    private func announceSplit(index: Int) {
        guard let mgr = manager, index < mgr.splitFractions.count else { return }
        Accessibility.announce(
            "\(accessibilityLabelForSplit(index: index)), \(Accessibility.percent(mgr.splitFractions[index])) percent")
    }

    // MARK: Split adjustment (shared by mouse, keyboard, accessibility)

    /// Set split `index` to `value`, clamped away from its neighbours and the edges.
    func setFraction(index idx: Int, to value: CGFloat) {
        guard let mgr = manager, idx >= 0, idx < mgr.splitFractions.count else { return }
        let clamped = max(splitLowerBound(idx), min(splitUpperBound(idx), value))
        guard clamped != mgr.splitFractions[idx] else { return }
        mgr.splitFractions[idx] = clamped
        selectedIndex = idx
        if idx < a11ySplits.count {
            NSAccessibility.post(element: a11ySplits[idx], notification: .valueChanged)
        }
        needsDisplay = true
    }

    /// The smallest value split `idx` may take without crossing its neighbour.
    func splitLowerBound(_ idx: Int) -> CGFloat {
        guard let mgr = manager, idx > 0, idx - 1 < mgr.splitFractions.count else { return minGap }
        return mgr.splitFractions[idx - 1] + minGap
    }

    /// The largest value split `idx` may take without crossing its neighbour.
    func splitUpperBound(_ idx: Int) -> CGFloat {
        guard let mgr = manager, idx + 1 < mgr.splitFractions.count else { return 1 - minGap }
        return mgr.splitFractions[idx + 1] - minGap
    }

    // MARK: Drag-and-drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = imageURLs(from: sender.draggingPasteboard).first,
              let mgr = manager else { return false }
        mgr.loadImage(from: url)
        return true
    }

    // MARK: Helpers

    /// The manager, but only when the current arrangement uses draggable splits.
    private func mgr(supportsSplits: Bool) -> WallpaperManager? {
        guard let mgr = manager, mgr.sourceImage != nil else { return nil }
        if supportsSplits, mgr.layout.arrangement == .grid { return nil }
        return mgr
    }

    private func imageDrawRect() -> NSRect? {
        guard let image = manager?.sourceImage else { return nil }
        return aspectFit(size: image.size, in: bounds)
    }

    /// Distance from `pt` to the split line at `fraction`, along the perpendicular axis.
    private func perpendicularDistance(of pt: NSPoint, fraction: CGFloat, axis: SplitAxis, in drawRect: NSRect) -> CGFloat {
        switch axis {
        case .horizontal: return pt.x - (drawRect.minX + drawRect.width * fraction)
        case .vertical:   return pt.y - (drawRect.maxY - drawRect.height * fraction)
        }
    }

    /// The split fraction that point `pt` represents along `axis`.
    private func fractionValue(of pt: NSPoint, axis: SplitAxis, in drawRect: NSRect) -> CGFloat {
        switch axis {
        case .horizontal: return (pt.x - drawRect.minX) / drawRect.width
        case .vertical:   return (drawRect.maxY - pt.y) / drawRect.height
        }
    }

    private func aspectFit(size: CGSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private func imageURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"]
        ]) as? [URL]) ?? []
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { "wallpaper preview" }

    override func accessibilityLabel() -> String? {
        guard let mgr = manager else { return "Wallpaper preview" }
        guard mgr.sourceImage != nil else {
            return "Wallpaper preview. No image loaded. Open an image with Command O, or drag and drop one here."
        }
        let n = max(sectionCount(mgr), 1)
        let displays = "\(n) display\(n == 1 ? "" : "s")"
        switch mgr.layout.arrangement {
        case .row:    return "Wallpaper preview spanning \(displays) in a row."
        case .column: return "Wallpaper preview spanning \(displays) in a column."
        case .grid:   return "Wallpaper preview spanning \(displays) arranged in a grid."
        }
    }

    /// The current framing, so a screen reader user can tell how much of the image
    /// is in play without inspecting each display section.
    override func accessibilityValue() -> Any? {
        guard let mgr = manager, mgr.sourceImage != nil else { return nil }
        return mgr.framingSummary
    }

    override func accessibilityHelp() -> String? {
        guard let mgr = manager, mgr.sourceImage != nil else {
            return "Press Command O to open an image."
        }
        let framing = "Zoom with Command Plus and Command Minus, Command 0 to fit, and move the image with Option and the arrow keys."
        switch mgr.layout.arrangement {
        case .grid:
            return "Each display is mapped to the matching region of the image. Split positions are fixed for grid arrangements. \(framing)"
        case .row:
            return "Navigate to a split line and adjust it with Control Option Left and Right, or select it on the canvas and use the arrow keys. Hold Shift for larger steps, or press Home and End to move it to its limits. \(framing)"
        case .column:
            return "Navigate to a split line and adjust it with Control Option Up and Down, or select it on the canvas and use the arrow keys. Hold Shift for larger steps, or press Home and End to move it to its limits. \(framing)"
        }
    }

    override func accessibilityChildren() -> [Any]? {
        _ = rebuildAccessibilityChildrenIfNeeded()
        guard !a11ySections.isEmpty else { return nil }
        // Interleave so VoiceOver walks the canvas in visual order:
        // screen, the split after it, the next screen, and so on.
        var children: [Any] = []
        for (i, section) in a11ySections.enumerated() {
            children.append(section)
            if i < a11ySplits.count { children.append(a11ySplits[i]) }
        }
        return children
    }

    /// Rebuild the accessibility elements if the structure changed. Returns whether
    /// anything was rebuilt.
    @discardableResult
    private func rebuildAccessibilityChildrenIfNeeded() -> Bool {
        guard let mgr = manager, mgr.sourceImage != nil else {
            let had = !a11ySections.isEmpty || !a11ySplits.isEmpty
            a11ySections = []; a11ySplits = []; a11yStructure = nil
            return had
        }
        let count = sectionCount(mgr)
        let structure = A11yStructure(
            arrangement: mgr.layout.arrangement,
            names: (0..<count).map(sectionName),
            splitCount: mgr.layout.arrangement == .grid ? 0 : mgr.splitFractions.count)
        guard structure != a11yStructure else { return false }

        a11yStructure = structure
        a11ySections = (0..<count).map { SectionAccessibilityElement(canvas: self, index: $0) }
        a11ySplits = (0..<structure.splitCount).map { SplitLineAccessibilityElement(canvas: self, index: $0) }
        return true
    }

    /// Screen-space frame of split handle `index`, for its accessibility element.
    func accessibilityHandleFrame(index: Int) -> NSRect {
        guard let mgr = manager, index < mgr.splitFractions.count, let drawRect = imageDrawRect(),
              let window = window else { return .zero }
        let f = mgr.splitFractions[index]
        let center: NSPoint = mgr.layout.axis == .horizontal
            ? NSPoint(x: drawRect.minX + drawRect.width * f, y: drawRect.midY)
            : NSPoint(x: drawRect.midX, y: drawRect.maxY - drawRect.height * f)
        let inView = NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
        return window.convertToScreen(convert(inView, to: nil))
    }

    /// Screen-space frame of the band belonging to display `index`.
    func accessibilitySectionFrame(index: Int) -> NSRect {
        guard let drawRect = imageDrawRect(), let window = window else { return .zero }
        let sections = sectionBands(in: drawRect)
        guard index < sections.count else { return .zero }
        return window.convertToScreen(convert(sections[index].rect, to: nil))
    }

    func fraction(at index: Int) -> CGFloat {
        guard let mgr = manager, index < mgr.splitFractions.count else { return 0 }
        return mgr.splitFractions[index]
    }

    func accessibilityLabelForSplit(index: Int) -> String {
        "Split line between \(sectionName(index)) and \(sectionName(index + 1))"
    }

    /// Mirror VoiceOver focus into the on-screen selection, so the visible focus
    /// ring and the VoiceOver cursor never disagree.
    func focusSplit(index: Int) {
        selectedIndex = index
        needsDisplay = true
    }

    func accessibilityLabelForSection(index: Int) -> String {
        guard let mgr = manager else { return sectionName(index) }
        return "\(sectionName(index)), display \(index + 1) of \(sectionCount(mgr))"
    }

    /// What this display will actually show: which part of the image it covers,
    /// and how much of that gets trimmed to match its shape.
    func accessibilityValueForSection(index: Int) -> String {
        guard let mgr = manager, let drawRect = imageDrawRect() else { return "" }
        let sections = sectionBands(in: drawRect)
        guard index < sections.count else { return "" }
        let s = sections[index]

        var parts: [String] = [spanDescription(for: s, in: drawRect, arrangement: mgr.layout.arrangement)]

        let kept = WallpaperGeometry.centerCrop(s.rect, toAspect: s.aspect)
        if s.rect.width > 0, kept.width < s.rect.width - 0.5 {
            let trimmed = Accessibility.percent((s.rect.width - kept.width) / s.rect.width)
            parts.append("\(trimmed) percent trimmed from the left and right to fit this display.")
        } else if s.rect.height > 0, kept.height < s.rect.height - 0.5 {
            let trimmed = Accessibility.percent((s.rect.height - kept.height) / s.rect.height)
            parts.append("\(trimmed) percent trimmed from the top and bottom to fit this display.")
        } else {
            parts.append("The whole slice fits this display.")
        }
        return parts.joined(separator: " ")
    }

    private func spanDescription(for s: Section, in drawRect: NSRect, arrangement: DisplayArrangement) -> String {
        guard drawRect.width > 0, drawRect.height > 0 else { return "" }
        let left   = Accessibility.percent((s.rect.minX - drawRect.minX) / drawRect.width)
        let right  = Accessibility.percent((s.rect.maxX - drawRect.minX) / drawRect.width)
        let top    = Accessibility.percent((drawRect.maxY - s.rect.maxY) / drawRect.height)
        let bottom = Accessibility.percent((drawRect.maxY - s.rect.minY) / drawRect.height)

        // Percentages are of what is on the canvas, which is the whole image only
        // when it is not zoomed — say which, so the figures are never ambiguous.
        let subject = manager?.isFramed == true ? "the visible area" : "the image"

        switch arrangement {
        case .row:
            return "Shows \(left) to \(right) percent across \(subject)."
        case .column:
            return "Shows \(top) to \(bottom) percent down \(subject)."
        case .grid:
            return "Shows \(left) to \(right) percent across and \(top) to \(bottom) percent down \(subject)."
        }
    }
}

// MARK: - Accessible display section

/// Exposes one display's slice of the panorama to VoiceOver, so screen reader
/// users can hear what each display will show — including in grid arrangements,
/// which have no split lines to navigate.
final class SectionAccessibilityElement: NSAccessibilityElement {
    private weak var canvas: CanvasNSView?
    private let index: Int

    init(canvas: CanvasNSView, index: Int) {
        self.canvas = canvas
        self.index = index
        super.init()
        setAccessibilityParent(canvas)
        setAccessibilityRole(.staticText)
    }

    override func accessibilityLabel() -> String? { canvas?.accessibilityLabelForSection(index: index) }
    override func accessibilityRoleDescription() -> String? { "display section" }
    override func accessibilityValue() -> Any? { canvas?.accessibilityValueForSection(index: index) }
    override func accessibilityFrame() -> NSRect { canvas?.accessibilitySectionFrame(index: index) ?? .zero }
}

// MARK: - Accessible split line

/// Exposes a single split line to VoiceOver as an adjustable slider. Increment /
/// decrement (Control-Option-arrow) nudge the split; the value is its percentage.
final class SplitLineAccessibilityElement: NSAccessibilityElement {
    private weak var canvas: CanvasNSView?
    private let index: Int
    private let step: CGFloat = 0.02

    init(canvas: CanvasNSView, index: Int) {
        self.canvas = canvas
        self.index = index
        super.init()
        setAccessibilityParent(canvas)
        setAccessibilityRole(.slider)
    }

    override func accessibilityLabel() -> String? { canvas?.accessibilityLabelForSplit(index: index) }
    override func accessibilityRoleDescription() -> String? { "split line" }
    override func accessibilityFrame() -> NSRect { canvas?.accessibilityHandleFrame(index: index) ?? .zero }

    // Sliders report numeric values; the spoken form comes from the value
    // description so VoiceOver says "45 percent" rather than bare "45".
    override func accessibilityValue() -> Any? {
        guard let canvas = canvas else { return nil }
        return NSNumber(value: Accessibility.percent(canvas.fraction(at: index)))
    }

    override func accessibilityValueDescription() -> String? {
        guard let canvas = canvas else { return nil }
        return "\(Accessibility.percent(canvas.fraction(at: index))) percent"
    }

    override func accessibilityMinValue() -> Any? {
        guard let canvas = canvas else { return nil }
        return NSNumber(value: Accessibility.percent(canvas.splitLowerBound(index)))
    }

    override func accessibilityMaxValue() -> Any? {
        guard let canvas = canvas else { return nil }
        return NSNumber(value: Accessibility.percent(canvas.splitUpperBound(index)))
    }

    override func accessibilityHelp() -> String? {
        "Adjust with Control Option Left and Right, or select this split line on the canvas and use the arrow keys."
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        if accessibilityFocused { canvas?.focusSplit(index: index) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(by: step)
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(by: -step)
    }

    private func adjust(by delta: CGFloat) -> Bool {
        guard let canvas = canvas else { return false }
        let before = canvas.fraction(at: index)
        canvas.setFraction(index: index, to: before + delta)
        // Report failure at the limits so VoiceOver can signal "no more room".
        return canvas.fraction(at: index) != before
    }
}
