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
    }
}

// MARK: - Interactive canvas view

final class CanvasNSView: NSView {
    var manager: WallpaperManager? { didSet { invalidateAccessibilityChildren(); needsDisplay = true } }

    private var draggingIndex: Int? = nil
    private var selectedIndex: Int? = nil
    private let minGap: CGFloat = 0.05
    private let hitThreshold: CGFloat = 16
    private var a11yChildren: [SplitLineAccessibilityElement] = []

    init(manager: WallpaperManager) {
        self.manager = manager
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        observeScreenChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        observeScreenChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Redraw when displays are reconfigured (e.g. a screen is rotated) so the
    // per-section crop preview reflects each screen's current aspect ratio.
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { invalidateAccessibilityChildren(); needsDisplay = true }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
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
            return
        }

        let drawRect = aspectFit(size: image.size, in: bounds)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)

        let sections = sectionBands(in: drawRect)
        drawCropDimming(sections)

        switch manager?.layout.arrangement ?? .row {
        case .row, .column:
            drawSplitLines(in: drawRect)
        case .grid:
            drawGridOutlines(sections)
        }

        drawSectionLabels(sections)
    }

    private func drawDropHint() {
        let text  = "Open an image with ⌘O  or  drag and drop here" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
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

    /// The on-canvas rectangle, target aspect, and label for each display's slice.
    private func sectionBands(in drawRect: NSRect) -> [Section] {
        guard let mgr = manager else { return [] }
        let slots = mgr.slots

        func aspect(_ i: Int) -> CGFloat { i < slots.count ? slots[i].aspect : drawRect.width / drawRect.height }
        func name(_ i: Int)   -> String  { i < slots.count ? slots[i].name : "Screen \(i + 1)" }

        switch mgr.layout.arrangement {
        case .row:
            let cuts: [CGFloat] = [0] + mgr.splitFractions.sorted() + [1]
            return (0..<cuts.count - 1).map { i in
                let xL = drawRect.minX + drawRect.width * cuts[i]
                let xR = drawRect.minX + drawRect.width * cuts[i + 1]
                return Section(rect: NSRect(x: xL, y: drawRect.minY, width: xR - xL, height: drawRect.height),
                               aspect: aspect(i), name: name(i))
            }
        case .column:
            let cuts: [CGFloat] = [0] + mgr.splitFractions.sorted() + [1]
            return (0..<cuts.count - 1).map { i in
                let yTop = drawRect.maxY - drawRect.height * cuts[i]      // cut 0 = top of image
                let yBot = drawRect.maxY - drawRect.height * cuts[i + 1]
                return Section(rect: NSRect(x: drawRect.minX, y: yBot, width: drawRect.width, height: yTop - yBot),
                               aspect: aspect(i), name: name(i))
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
                return Section(rect: rect, aspect: slot.aspect, name: slot.name)
            }
        }
    }

    /// Dim the parts of each section that will be cropped away, so the preview
    /// shows exactly what lands on each display (mirrors WallpaperGeometry.centerCrop).
    private func drawCropDimming(_ sections: [Section]) {
        NSColor.black.withAlphaComponent(0.55).setFill()
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

            drawDashedLine(from: a, to: b)

            let handleRect = NSRect(x: handleCenter.x - 10, y: handleCenter.y - 10, width: 20, height: 20)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            let border = NSBezierPath(ovalIn: handleRect)
            border.lineWidth = 2
            NSColor.systemBlue.setStroke()
            border.stroke()

            // Focus ring on the keyboard-selected handle.
            if focused, i == selectedIndex {
                let ring = NSBezierPath(ovalIn: handleRect.insetBy(dx: -4, dy: -4))
                ring.lineWidth = 3
                NSColor.keyboardFocusIndicatorColor.setStroke()
                ring.stroke()
            }
        }
    }

    private func drawDashedLine(from a: NSPoint, to b: NSPoint) {
        // Shadow offset by 1pt for contrast against any image colour.
        let shadow = NSBezierPath()
        shadow.move(to: NSPoint(x: a.x + 1, y: a.y - 1)); shadow.line(to: NSPoint(x: b.x + 1, y: b.y - 1))
        shadow.lineWidth = 2; shadow.setLineDash([8, 4], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.35).setStroke(); shadow.stroke()

        let line = NSBezierPath()
        line.move(to: a); line.line(to: b)
        line.lineWidth = 2; line.setLineDash([8, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke(); line.stroke()
    }

    private func drawGridOutlines(_ sections: [Section]) {
        NSColor.white.withAlphaComponent(0.85).setStroke()
        for s in sections {
            let path = NSBezierPath(rect: s.rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([8, 4], count: 2, phase: 0)
            path.stroke()
        }
    }

    private func drawSectionLabels(_ sections: [Section]) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .shadow: {
                let s = NSShadow(); s.shadowColor = .black; s.shadowBlurRadius = 3; return s
            }()
        ]
        for s in sections {
            let label = s.name as NSString
            let sz = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: s.rect.midX - sz.width / 2, y: s.rect.minY + 8), withAttributes: attrs)
        }
    }

    // MARK: Mouse — drag split lines

    override func mouseDown(with event: NSEvent) {
        guard let mgr = mgr(supportsSplits: true),
              let drawRect = imageDrawRect() else { return }
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        draggingIndex = nil
        for (i, fraction) in mgr.splitFractions.enumerated()
        where abs(perpendicularDistance(of: pt, fraction: fraction, axis: mgr.layout.axis, in: drawRect)) < hitThreshold {
            draggingIndex = i
            selectedIndex = i
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let idx = draggingIndex, let mgr = manager, let drawRect = imageDrawRect() else { return }
        let pt = convert(event.locationInWindow, from: nil)
        setFraction(index: idx, to: fractionValue(of: pt, axis: mgr.layout.axis, in: drawRect))
    }

    override func mouseUp(with event: NSEvent) { draggingIndex = nil }

    // MARK: Keyboard — nudge / select split lines

    override func keyDown(with event: NSEvent) {
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
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(by delta: CGFloat) {
        guard let mgr = manager else { return }
        if selectedIndex == nil { selectedIndex = 0 }
        guard let idx = selectedIndex, idx < mgr.splitFractions.count else { return }
        setFraction(index: idx, to: mgr.splitFractions[idx] + delta)
    }

    private func changeSelection(_ delta: Int) {
        guard let mgr = manager, !mgr.splitFractions.isEmpty else { return }
        let count = mgr.splitFractions.count
        let current = selectedIndex ?? 0
        selectedIndex = max(0, min(count - 1, current + delta))
        needsDisplay = true
    }

    // MARK: Split adjustment (shared by mouse, keyboard, accessibility)

    /// Set split `index` to `value`, clamped away from its neighbours and the edges.
    func setFraction(index idx: Int, to value: CGFloat) {
        guard let mgr = manager, idx >= 0, idx < mgr.splitFractions.count else { return }
        let fractions = mgr.splitFractions
        let lower = idx > 0                   ? fractions[idx - 1] + minGap : minGap
        let upper = idx < fractions.count - 1 ? fractions[idx + 1] - minGap : 1 - minGap
        mgr.splitFractions[idx] = max(lower, min(upper, value))
        selectedIndex = idx
        invalidateAccessibilityChildren()
        needsDisplay = true
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

    override func accessibilityLabel() -> String? {
        guard let mgr = manager else { return "Wallpaper canvas" }
        guard mgr.sourceImage != nil else { return "Wallpaper canvas. No image loaded. Open an image with Command O or drag and drop." }
        let n = mgr.slots.count
        switch mgr.layout.arrangement {
        case .row:    return "Panorama preview across \(n) displays in a row. Drag or arrow-key the split lines to adjust."
        case .column: return "Panorama preview across \(n) displays in a column. Drag or arrow-key the split lines to adjust."
        case .grid:   return "Panorama preview across \(n) displays arranged in a grid. Split positions are fixed for grid layouts."
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let mgr = manager, mgr.sourceImage != nil,
              mgr.layout.arrangement != .grid, !mgr.splitFractions.isEmpty else { return nil }
        if a11yChildren.count != mgr.splitFractions.count {
            a11yChildren = mgr.splitFractions.indices.map { SplitLineAccessibilityElement(canvas: self, index: $0) }
        }
        return a11yChildren
    }

    private func invalidateAccessibilityChildren() {
        a11yChildren.removeAll()
    }

    /// Screen-space frame of split handle `index`, for its accessibility element.
    func accessibilityHandleFrame(index: Int) -> NSRect {
        guard let mgr = manager, index < mgr.splitFractions.count, let drawRect = imageDrawRect(),
              let window = window else { return .zero }
        let f = mgr.splitFractions[index]
        let center: NSPoint = mgr.layout.axis == .horizontal
            ? NSPoint(x: drawRect.minX + drawRect.width * f, y: drawRect.midY)
            : NSPoint(x: drawRect.midX, y: drawRect.maxY - drawRect.height * f)
        let inView = NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
        return window.convertToScreen(convert(inView, to: nil))
    }

    func fraction(at index: Int) -> CGFloat {
        guard let mgr = manager, index < mgr.splitFractions.count else { return 0 }
        return mgr.splitFractions[index]
    }

    func accessibilityLabelForSplit(index: Int) -> String {
        guard let mgr = manager else { return "Split line" }
        let a = index < mgr.slots.count ? mgr.slots[index].name : "Screen \(index + 1)"
        let b = index + 1 < mgr.slots.count ? mgr.slots[index + 1].name : "Screen \(index + 2)"
        return "Split line between \(a) and \(b)"
    }
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

    override func accessibilityValue() -> Any? {
        guard let canvas = canvas else { return nil }
        return "\(Int((canvas.fraction(at: index) * 100).rounded()))%"
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard let canvas = canvas else { return false }
        canvas.setFraction(index: index, to: canvas.fraction(at: index) + step)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let canvas = canvas else { return false }
        canvas.setFraction(index: index, to: canvas.fraction(at: index) - step)
        return true
    }
}
