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

    private var isDragging = false

    init(manager: WallpaperManager) {
        self.manager = manager
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1.0).setFill()
        bounds.fill()

        guard let image = manager?.sourceImage else {
            drawDropHint()
            return
        }

        let drawRect = aspectFit(size: image.size, in: bounds)
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        drawSplitLine(in: drawRect)
    }

    private func drawDropHint() {
        let text = "Open an image with ⌘O  or  drag and drop here" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let sz = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2),
            withAttributes: attrs
        )
    }

    private func drawSplitLine(in drawRect: NSRect) {
        let fraction = manager?.splitFraction ?? 0.5
        let lineX = drawRect.minX + drawRect.width * fraction

        // Shadow stroke for contrast against any image colour
        let draw = { (color: NSColor, offset: CGFloat, width: CGFloat) in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: lineX + offset, y: drawRect.minY))
            p.line(to: NSPoint(x: lineX + offset, y: drawRect.maxY))
            p.lineWidth = width
            p.setLineDash([8, 4], count: 2, phase: 0)
            color.setStroke()
            p.stroke()
        }
        draw(NSColor.black.withAlphaComponent(0.35), 1, 2)
        draw(NSColor.white.withAlphaComponent(0.9),   0, 2)

        // Drag handle
        let handleRect = NSRect(x: lineX - 10, y: drawRect.midY - 10, width: 20, height: 20)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: handleRect).fill()
        let border = NSBezierPath(ovalIn: handleRect)
        border.lineWidth = 2
        NSColor.systemBlue.setStroke()
        border.stroke()

        // Labels
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75)
        ]
        ("Screen 1" as NSString).draw(at: NSPoint(x: drawRect.minX + 8, y: drawRect.minY + 8), withAttributes: labelAttrs)
        ("Screen 2" as NSString).draw(at: NSPoint(x: lineX + 8,         y: drawRect.minY + 8), withAttributes: labelAttrs)
    }

    // MARK: Mouse — drag split line

    override func mouseDown(with event: NSEvent) {
        guard manager?.sourceImage != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        isDragging = abs(pt.x - splitLineX()) < 16
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let mgr = manager, let image = mgr.sourceImage else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let drawRect = aspectFit(size: image.size, in: bounds)
        mgr.splitFraction = max(0.05, min(0.95, (pt.x - drawRect.minX) / drawRect.width))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { isDragging = false }

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

    private func splitLineX() -> CGFloat {
        guard let mgr = manager, let img = mgr.sourceImage else { return bounds.midX }
        let drawRect = aspectFit(size: img.size, in: bounds)
        return drawRect.minX + drawRect.width * mgr.splitFraction
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
