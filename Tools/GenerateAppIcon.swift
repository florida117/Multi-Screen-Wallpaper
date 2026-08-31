// Regenerates the app icon into MultiScreenWallpaper/Assets.xcassets/AppIcon.appiconset.
//
//   swift Tools/GenerateAppIcon.swift MultiScreenWallpaper/Assets.xcassets/AppIcon.appiconset
//
// The icon is two `display` SF Symbols side by side on a neutral squircle, with a
// single horizontal gradient laid across BOTH screens so the image visibly continues
// from one monitor to the next — the app's whole premise, in one glyph.
//
// Each size is rendered natively rather than downscaled from a master, so SF Symbols'
// optical scaling keeps the bezel strokes crisp at 16pt and 32pt.
//
// Contents.json is checked in and is not touched by this script; if you change the
// `targets` list below, update it to match.

import AppKit

// MARK: - Tunables

/// Combined width of the two monitors, as a fraction of the icon. Past ~0.92 the art
/// crowds the squircle's corners at Dock sizes.
let pairWidth: CGFloat = 0.90

/// Visible gap between the two monitors, as a fraction of the icon. This is the gap you
/// actually see — see the ink-edge note in `monitorRects`.
let gap: CGFloat = 0.004

/// Drawn across both screens as one continuous span.
let panorama = NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.30, blue: 0.70, alpha: 1),
    NSColor(srgbRed: 0.49, green: 0.32, blue: 0.78, alpha: 1),
    NSColor(srgbRed: 0.93, green: 0.40, blue: 0.46, alpha: 1),
    NSColor(srgbRed: 0.99, green: 0.72, blue: 0.33, alpha: 1),
])!

let inkColor = NSColor(calibratedWhite: 0.15, alpha: 1)
let backgroundColors = [NSColor(calibratedWhite: 0.96, alpha: 1),
                        NSColor(calibratedWhite: 0.845, alpha: 1)]

// MARK: - `display` glyph metrics
//
// Measured by rasterising the symbol at 512pt wide (glyph box 724x574, so 512x406 px):
// the drawn frame spans x 45..466 and y 28..315 top-down, the stand ends at y 385, and
// the stroke is ~29px. Everything below is expressed as a fraction of the symbol's box.
//
// NOTE: these come from the SF Symbols version on the machine that rendered them. If
// Apple redraws `display`, re-measure before trusting a regenerated icon.

/// Outer edges of the drawn frame — the glyph carries ~9% empty side bearing inside its
/// box, which is why laying out from the box leaves a stubborn gap between monitors.
let inkX0: CGFloat = 45.0 / 512, inkX1: CGFloat = 466.0 / 512
/// Top of the frame down to the bottom of the stand.
let inkY0: CGFloat = 28.0 / 406, inkY1: CGFloat = 385.0 / 406
/// Inside of the frame — the screen area the panorama fills.
let screenX0: CGFloat = 74.0 / 512, screenX1: CGFloat = 437.0 / 512
let screenY0: CGFloat = 57.0 / 406, screenY1: CGFloat = 286.0 / 406  // from the top

// MARK: - Drawing

func squircle(_ rect: NSRect) -> NSBezierPath {
    let radius = rect.width * 0.2237
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Renders an SF Symbol aspect-fit into an image of `size`, flooded with `tint`.
func symbolImage(_ name: String, size: NSSize, tint: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: max(size.width, size.height), weight: .regular)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { fatalError("missing SF Symbol: \(name)") }

    let image = NSImage(size: size)
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = min(size.width / symbol.size.width, size.height / symbol.size.height)
    let w = symbol.size.width * scale, h = symbol.size.height * scale
    symbol.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
    NSGraphicsContext.current?.compositingOperation = .sourceAtop
    tint.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
}

/// Height/width of the `display` symbol's box.
func displayAspect() -> CGFloat {
    let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 100, weight: .regular))!
    return symbol.size.height / symbol.size.width
}

/// The screen area inside one monitor's frame.
func screenRect(in rect: NSRect) -> NSRect {
    NSRect(x: rect.minX + screenX0 * rect.width,
           y: rect.maxY - screenY1 * rect.height,
           width: (screenX1 - screenX0) * rect.width,
           height: (screenY1 - screenY0) * rect.height)
}

/// Symbol boxes for the two monitors, positioned so that `pairWidth` and `gap` describe
/// the *visible* frames rather than the boxes (which are padded by the glyph's bearing).
func monitorRects(size: CGFloat) -> [NSRect] {
    let visibleWidth = size * pairWidth, visibleGap = size * gap
    let boxWidth = ((visibleWidth - visibleGap) / 2) / (inkX1 - inkX0)
    let boxHeight = boxWidth * displayAspect()
    let boxGap = visibleGap - (inkX0 + (1 - inkX1)) * boxWidth

    let x0 = (size - visibleWidth) / 2 - inkX0 * boxWidth
    // Centre the drawn glyph, not its padded box, or the stand drags the art off-centre.
    let y0 = (size - (inkY1 - inkY0) * boxHeight) / 2 - (1 - inkY1) * boxHeight

    return (0..<2).map { i in
        NSRect(x: x0 + CGFloat(i) * (boxWidth + boxGap), y: y0, width: boxWidth, height: boxHeight)
    }
}

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    squircle(bounds).addClip()
    NSGradient(colors: backgroundColors)!.draw(in: bounds, angle: -90)
    NSColor(calibratedWhite: 0, alpha: 0.10).setStroke()
    let edge = squircle(bounds.insetBy(dx: size * 0.005, dy: size * 0.005))
    edge.lineWidth = size * 0.008
    edge.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let rects = monitorRects(size: size)

    // One gradient spanning both screens, clipped into each. The fill bleeds slightly
    // outward so it tucks under the bezel stroke instead of leaving a pale seam.
    let left = screenRect(in: rects[0]), right = screenRect(in: rects[1])
    let span = NSRect(x: left.minX, y: left.minY, width: right.maxX - left.minX, height: left.height)
    for screen in [left, right] {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: screen.insetBy(dx: -size * 0.006, dy: -size * 0.006),
                     xRadius: size * 0.016, yRadius: size * 0.016).addClip()
        panorama.draw(in: span, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    for rect in rects {
        symbolImage("display", size: rect.size, tint: inkColor).draw(in: rect)
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to path: String, size: CGFloat) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - Entry point

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("""
        usage: swift Tools/GenerateAppIcon.swift <AppIcon.appiconset directory>

        """.utf8))
    exit(1)
}
let outputDirectory = CommandLine.arguments[1]

// Every pixel size Contents.json references, across all @1x/@2x macOS slots.
let targets: [Int] = [16, 32, 64, 128, 256, 512, 1024]
for pixels in targets {
    let size = CGFloat(pixels)
    writePNG(makeIcon(size: size), to: "\(outputDirectory)/icon_\(pixels).png", size: size)
    print("wrote icon_\(pixels).png")
}
