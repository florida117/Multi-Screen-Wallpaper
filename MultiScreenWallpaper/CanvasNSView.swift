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
    var manager: WallpaperManager? { didSet { needsDisplay = true } }

    private var draggingIndex: Int? = nil
    private let minGap: CGFloat = 0.05

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
    // per-section crop preview reflects each screen's current aspect ratio,
    // even when the number of displays — and thus the split lines — is unchanged.
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Use the system window background when empty so it respects light/dark mode.
        // Switch to black once an image is loaded to give clean letterboxing.
        let background: NSColor = manager?.sourceImage != nil ? .black : .windowBackgroundColor
        background.setFill()
        bounds.fill()

        guard let image = manager?.sourceImage else {
            drawDropHint()
            return
        }

        let drawRect = aspectFit(size: image.size, in: bounds)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        drawCropDimming(in: drawRect)
        drawSplitLines(in: drawRect)
    }

    /// Dim the parts of each section that will be cropped away, so the preview
    /// shows exactly what lands on each display. Each section is center-cropped
    /// to its screen's aspect ratio — mirroring `WallpaperManager.cropAndSave`.
    private func drawCropDimming(in drawRect: NSRect) {
        guard let mgr = manager else { return }
        let cuts: [CGFloat] = [0] + mgr.splitFractions + [1]
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }

        NSColor.black.withAlphaComponent(0.55).setFill()
        for i in 0..<cuts.count - 1 {
            guard i < screens.count else { continue }
            let xL = xPosition(for: cuts[i], in: drawRect)
            let xR = xPosition(for: cuts[i + 1], in: drawRect)
            let band = NSRect(x: xL, y: drawRect.minY, width: xR - xL, height: drawRect.height)

            // Screen aspect is scale-independent (backing factor cancels).
            let f = screens[i].frame
            let kept = centerCrop(band, toAspect: f.width / f.height)

            if kept.width < band.width {
                NSRect(x: band.minX, y: band.minY,
                       width: kept.minX - band.minX, height: band.height).fill()
                NSRect(x: kept.maxX, y: band.minY,
                       width: band.maxX - kept.maxX, height: band.height).fill()
            } else if kept.height < band.height {
                NSRect(x: band.minX, y: band.minY,
                       width: band.width, height: kept.minY - band.minY).fill()
                NSRect(x: band.minX, y: kept.maxY,
                       width: band.width, height: band.maxY - kept.maxY).fill()
            }
        }
    }

    private func centerCrop(_ rect: NSRect, toAspect targetAspect: CGFloat) -> NSRect {
        if rect.width / rect.height > targetAspect {
            let w = rect.height * targetAspect
            return NSRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
        } else {
            let h = rect.width / targetAspect
            return NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        }
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

    private func drawSplitLines(in drawRect: NSRect) {
        guard let mgr = manager else { return }
        let fractions = mgr.splitFractions
        let screens   = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }

        // Draw each split line and its handle.
        for fraction in fractions {
            let lineX = xPosition(for: fraction, in: drawRect)

            // Shadow for contrast against any image colour.
            let shadow = NSBezierPath()
            shadow.move(to: NSPoint(x: lineX + 1, y: drawRect.minY))
            shadow.line(to: NSPoint(x: lineX + 1, y: drawRect.maxY))
            shadow.lineWidth = 2
            shadow.setLineDash([8, 4], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.35).setStroke()
            shadow.stroke()

            let line = NSBezierPath()
            line.move(to: NSPoint(x: lineX, y: drawRect.minY))
            line.line(to: NSPoint(x: lineX, y: drawRect.maxY))
            line.lineWidth = 2
            line.setLineDash([8, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            line.stroke()

            let handleRect = NSRect(x: lineX - 10, y: drawRect.midY - 10, width: 20, height: 20)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            let border = NSBezierPath(ovalIn: handleRect)
            border.lineWidth = 2
            NSColor.systemBlue.setStroke()
            border.stroke()
        }

        // Label each section with the corresponding screen name.
        let allCuts: [CGFloat] = [0] + fractions + [1]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75)
        ]
        for i in 0..<allCuts.count - 1 {
            let midX   = xPosition(for: (allCuts[i] + allCuts[i + 1]) / 2, in: drawRect)
            let name   = i < screens.count ? screens[i].localizedName : "Screen \(i + 1)"
            let label  = name as NSString
            let sz     = label.size(withAttributes: labelAttrs)
            label.draw(at: NSPoint(x: midX - sz.width / 2, y: drawRect.minY + 8),
                       withAttributes: labelAttrs)
        }
    }

    // MARK: Mouse — drag split lines

    override func mouseDown(with event: NSEvent) {
        guard let mgr = manager, mgr.sourceImage != nil,
              let drawRect = imageDrawRect() else { return }
        let pt = convert(event.locationInWindow, from: nil)
        draggingIndex = nil
        for (i, fraction) in mgr.splitFractions.enumerated() {
            if abs(pt.x - xPosition(for: fraction, in: drawRect)) < 16 {
                draggingIndex = i
                break
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let idx = draggingIndex,
              let mgr = manager,
              let drawRect = imageDrawRect() else { return }

        let pt          = convert(event.locationInWindow, from: nil)
        var newFraction = (pt.x - drawRect.minX) / drawRect.width

        // Keep the line away from its neighbours and the edges.
        let fractions = mgr.splitFractions
        let lower = idx > 0                    ? fractions[idx - 1] + minGap : minGap
        let upper = idx < fractions.count - 1  ? fractions[idx + 1] - minGap : 1 - minGap
        newFraction = max(lower, min(upper, newFraction))

        mgr.splitFractions[idx] = newFraction
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { draggingIndex = nil }

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

    private func imageDrawRect() -> NSRect? {
        guard let image = manager?.sourceImage else { return nil }
        return aspectFit(size: image.size, in: bounds)
    }

    private func xPosition(for fraction: CGFloat, in drawRect: NSRect) -> CGFloat {
        drawRect.minX + drawRect.width * fraction
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
}
