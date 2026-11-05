import SwiftUI
import UniformTypeIdentifiers

/// "On your desk": every display drawn where it sits in Displays settings, each
/// showing exactly the part of the image an apply will give it.
///
/// The crops come from `WallpaperManager.deskCrops`, which calls the same
/// geometry the renderer does, so this view is a faithful preview rather than an
/// approximation of the result. Displays macOS has front-view artwork for (a
/// Studio Display, say) are drawn with it; anything else gets a generic outline.
struct DeskPreviewView: View {
    @ObservedObject var manager: WallpaperManager

    /// Height of the name and share caption under a display in a row.
    private let captionHeight: CGFloat = 44
    /// Height of the drawn stand used when there is no artwork.
    private let drawnStandHeight: CGFloat = 31
    /// Inset on every side of each display, so neighbours read as separate.
    private let separation: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(placements(in: geo.size)) { placement in
                    DeskDisplayView(placement: placement,
                                    thumbnail: manager.sourceThumbnail,
                                    showsStand: manager.layout.arrangement == .row)
                        .frame(width: placement.rect.width)
                        .offset(x: placement.rect.minX, y: placement.rect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Desk preview")
    }

    /// Where each display goes in a view of `size`, scaled to fit while keeping
    /// the physical arrangement (global frames are Y-up; SwiftUI is Y-down).
    private func placements(in size: CGSize) -> [DeskPlacement] {
        let slots = manager.slots
        let union = manager.unionBox
        guard !slots.isEmpty, union.width > 0, union.height > 0 else { return [] }

        let isRow = manager.layout.arrangement == .row
        let artworks = slots.map { DeviceArtwork.forSlot($0) }

        // In a row, room is needed under the displays for stands and captions.
        // Artwork stands scale with their display; drawn stands are fixed.
        var fixedFooter: CGFloat = 0
        var scaledFooter: CGFloat = 0   // in the displays' own points
        if isRow {
            fixedFooter = captionHeight
            for (slot, artwork) in zip(slots, artworks) {
                if let artwork {
                    scaledFooter = max(scaledFooter, artwork.standHeight(forWidth: slot.frame.width))
                } else {
                    fixedFooter = captionHeight + drawnStandHeight
                }
            }
        }

        // A laptop base at either end spills past its display; leave room so it
        // is not cut off at the edge of the view.
        var leftSpill: CGFloat = 0, rightSpill: CGFloat = 0   // in the displays' own points
        if isRow {
            for (slot, artwork) in zip(slots, artworks) {
                guard let artwork else { continue }
                let spill = artwork.overhang * slot.frame.width
                leftSpill = max(leftSpill, spill - (slot.frame.minX - union.minX))
                rightSpill = max(rightSpill, spill - (union.maxX - slot.frame.maxX))
            }
        }

        let margin: CGFloat = 8
        let scaleX: CGFloat = (size.width - 2 * margin) / (union.width + leftSpill + rightSpill)
        let scaleY: CGFloat = (size.height - 2 * margin - fixedFooter) / (union.height + scaledFooter)
        let scale: CGFloat = max(0, min(scaleX, scaleY))
        let footer: CGFloat = fixedFooter + scaledFooter * scale
        let originX: CGFloat = (size.width - (union.width + leftSpill + rightSpill) * scale) / 2
            + leftSpill * scale
        let originY: CGFloat = (size.height - footer - union.height * scale) / 2

        let crops = manager.deskCrops
        let shares = manager.slotShares
        let subject = manager.isFramed ? "visible area" : "image"

        var result: [DeskPlacement] = []
        for (i, slot) in slots.enumerated() {
            let f = slot.frame
            let x: CGFloat = originX + (f.minX - union.minX) * scale
            let y: CGFloat = originY + (union.maxY - f.maxY) * scale
            let rect = CGRect(x: x, y: y, width: f.width * scale, height: f.height * scale)
                .insetBy(dx: separation, dy: separation)
            var share: String?
            if i < shares.count {
                share = "\(Accessibility.percent(shares[i]))% of the \(subject)"
            }
            result.append(DeskPlacement(id: i, slot: slot, rect: rect,
                                        crop: i < crops.count ? crops[i] : nil,
                                        share: share, artwork: artworks[i]))
        }
        return result
    }
}

struct DeskPlacement: Identifiable {
    let id: Int
    let slot: SpanSlot
    /// The display's outline in the desk view, top-left origin.
    let rect: CGRect
    /// The unit rectangle of the source it shows (Y-up), or nil with no image.
    let crop: CGRect?
    /// e.g. "36% of the image"; nil for a grid, which maps by position.
    let share: String?
    /// The device's own artwork, when macOS has a usable one.
    let artwork: DeviceArtwork?
}

// MARK: - One display

/// One display on the desk: its crop of the image inside either the device's
/// own artwork or a generic bezel, with a stand and caption in a row.
private struct DeskDisplayView: View {
    let placement: DeskPlacement
    let thumbnail: CGImage?
    let showsStand: Bool

    private let bezel = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            if let artwork = placement.artwork {
                artworkDisplay(artwork)
            } else {
                drawnScreen
                if showsStand { drawnStand }
            }
            if showsStand {
                caption.padding(.top, 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placement.slot.name)
        .accessibilityValue(accessibilityValue)
    }

    // MARK: Artwork

    /// The device artwork scaled so its bezel spans the display's width, with
    /// the crop laid into the artwork's own screen area. In a row the whole
    /// artwork shows, stand included; otherwise it is cut off below the bezel
    /// so it cannot overlap the display underneath.
    private func artworkDisplay(_ artwork: DeviceArtwork) -> some View {
        let side = placement.rect.width / artwork.bezel.width   // rendered artwork size
        func local(_ unit: CGRect) -> CGRect {
            CGRect(x: (unit.minX - artwork.bezel.minX) * side, y: (unit.minY - artwork.bezel.minY) * side,
                   width: unit.width * side, height: unit.height * side)
        }
        let screenArea = local(artwork.screen)
        // The artwork's screen is within a few percent of the display's shape;
        // fit the crop to the display's exact shape so it is never stretched.
        let screen = fit(aspect: placement.slot.aspect, in: screenArea)
        let height = showsStand
            ? (artwork.bottom - artwork.bezel.minY) * side
            : artwork.bezel.height * side

        return ZStack(alignment: .topLeading) {
            Image(nsImage: artwork.image)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .offset(x: -artwork.bezel.minX * side, y: -artwork.bezel.minY * side)
            screenContent
                .frame(width: screen.width, height: screen.height)
                .offset(x: screen.minX, y: screen.minY)
            if let notch = artwork.notch.map(local) {
                // The notch sits over the wallpaper's top edge, as on the real
                // display. Extended upward so only its lower corners are rounded.
                let radius = notch.height * 0.45
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height + radius)
                    .offset(x: notch.minX, y: notch.minY - radius)
            }
        }
        .frame(width: placement.rect.width, height: height, alignment: .topLeading)
        // Always clip top and bottom; with the stand shown, let the sides spill
        // over, since a laptop's base is wider than its screen.
        .mask {
            Rectangle().padding(.horizontal, showsStand ? -placement.rect.width / 2 : 0)
        }
        .overlay(alignment: .top) {
            if !showsStand { chip.padding(.top, max(screen.maxY - 32, 0)) }
        }
    }

    /// The largest rectangle of `aspect` (width / height) centred in `rect`.
    private func fit(aspect: CGFloat, in rect: CGRect) -> CGRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return rect }
        if rect.width / rect.height > aspect {
            let w = rect.height * aspect
            return CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
        }
        let h = rect.width / aspect
        return CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
    }

    // MARK: Drawn fallback

    private var drawnScreen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: placement.slot.isBuiltIn ? 7 : 6)
                .fill(bezel)
            screenContent
                .aspectRatio(placement.slot.aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(5)
        }
        .frame(width: placement.rect.width, height: placement.rect.height)
        .overlay(alignment: .bottom) {
            if !showsStand { chip.padding(8) }
        }
    }

    @ViewBuilder
    private var drawnStand: some View {
        if placement.slot.isBuiltIn {
            // A laptop's base reaches a little past its screen on either side.
            UnevenBase()
                .fill(Color(white: 0.68))
                .frame(width: placement.rect.width * 1.1, height: 8)
        } else {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(white: 0.68))
                    .frame(width: max(placement.rect.width * 0.14, 8), height: 26)
                Capsule()
                    .fill(Color(white: 0.56))
                    .frame(width: placement.rect.width * 0.36, height: 5)
            }
        }
    }

    // MARK: Shared pieces

    @ViewBuilder
    private var screenContent: some View {
        if let thumbnail, let crop = placement.crop, crop.width > 0, crop.height > 0 {
            CroppedImage(image: thumbnail, crop: crop)
        } else {
            Color(white: 0.2)
        }
    }

    private var caption: some View {
        VStack(spacing: 2) {
            Text(placement.slot.name)
                .font(.callout.weight(.semibold))
            if let share = placement.share {
                Text(share)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: max(placement.rect.width, 140))
    }

    /// For columns and grids, where a caption below would sit on the next display.
    private var chip: some View {
        Text(placement.share.map { "\(placement.slot.name) · \($0)" } ?? placement.slot.name)
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.72)))
    }

    private var accessibilityValue: String {
        guard placement.crop != nil, thumbnail != nil else { return "No image" }
        return placement.share.map { "Shows \($0)" } ?? "Shows the region matching its position"
    }
}

/// A laptop base: square at the hinge, rounded where it meets the desk.
private struct UnevenBase: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.height, 6)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Shows `crop` (a unit rectangle of `image`, Y-up) filling the view.
private struct CroppedImage: View {
    let image: CGImage
    let crop: CGRect

    var body: some View {
        GeometryReader { geo in
            // Scale the whole image so the crop fills the view, then slide it so
            // the crop's top-left lands at the origin.
            let fullWidth = geo.size.width / crop.width
            let fullHeight = geo.size.height / crop.height
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: fullWidth, height: fullHeight)
                .offset(x: -crop.minX * fullWidth, y: -(1 - crop.maxY) * fullHeight)
        }
        .clipped()
    }
}

// MARK: - Device artwork

/// A display's own front-view artwork as macOS ships it (the icon behind the
/// system's device types, such as `com.apple.studio-display`), loaded at run
/// time rather than bundled, with where its screen, bezel and stand sit.
///
/// Those positions are measured from the artwork itself rather than hard-coded,
/// so a redrawn icon in a later macOS still lines up; anything that does not
/// look like a straight-on display whose screen matches the real one's shape
/// is rejected, and the preview falls back to a drawn outline.
struct DeviceArtwork {
    let image: NSImage
    /// Unit rectangles of the (square) artwork, top-left origin.
    let screen: CGRect
    /// The screen plus its frame, without the stand.
    let bezel: CGRect
    /// The lowest opaque point beneath the screen's centre: the stand's foot,
    /// or a laptop's front edge.
    let bottom: CGFloat
    /// A MacBook's camera notch, which covers the top of the wallpaper.
    let notch: CGRect?
    /// The screen area's width over height.
    let screenAspect: CGFloat
    /// How far the widest part below the bezel (a laptop's base) reaches past
    /// each side of the bezel, as a fraction of the bezel's width.
    let overhang: CGFloat

    /// How far the stand reaches below the bezel when the display is drawn
    /// `width` wide.
    func standHeight(forWidth width: CGFloat) -> CGFloat {
        max(bottom - bezel.maxY, 0) * width / bezel.width
    }

    /// The artwork for `slot`'s device, if macOS has one that fits it.
    static func forSlot(_ slot: SpanSlot) -> DeviceArtwork? {
        guard let type = deviceType(for: slot), let artwork = measured(type) else { return nil }
        // The crop is drawn into the artwork's screen; a different shape would
        // stretch it or misrepresent what the display shows.
        guard abs(artwork.screenAspect - slot.aspect) / slot.aspect < 0.06 else { return nil }
        return artwork
    }

    // MARK: Which device

    private static let appleVendorID: UInt32 = 0x610
    private static let modelCodeTag = UTTagClass(rawValue: "com.apple.device-model-code")

    /// Apple displays macOS knows by type. Matched on their localised names,
    /// since there is no public call from a display to its model code.
    private static let externalDisplayTypes = [
        "com.apple.studio-display",
        "com.apple.pro-display-xdr",
        "com.apple.led-cinema-display-27",
        "com.apple.led-cinema-display-24",
        "com.apple.cinema-display",
    ]

    private static func deviceType(for slot: SpanSlot) -> UTType? {
        if slot.isBuiltIn {
            // A built-in panel is this Mac's, so use the Mac's own model.
            guard let model = hardwareModel(),
                  let type = UTType(tag: model, tagClass: modelCodeTag, conformingTo: nil),
                  !type.isDynamic else { return nil }
            return type
        }
        guard let id = slot.displayID, CGDisplayVendorNumber(id) == appleVendorID else { return nil }
        // macOS appends " (1)", " (2)" when several identical displays are attached.
        let baseName = slot.name.replacingOccurrences(of: #"\s\(\d+\)$"#, with: "",
                                                      options: .regularExpression)
        return externalDisplayTypes.lazy
            .compactMap { UTType($0) }
            .first { $0.localizedDescription == baseName }
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Measuring the artwork

    /// Measurements per device type. Only touched from the main thread (views).
    private static var cache: [String: DeviceArtwork?] = [:]

    private static func measured(_ type: UTType) -> DeviceArtwork? {
        if let cached = cache[type.identifier] { return cached }
        let artwork = measure(type)
        cache[type.identifier] = artwork
        return artwork
    }

    /// Find the screen by walking out from the artwork's centre: the screen is
    /// the lit area, ringed by a near-black bezel, with transparency beyond.
    private static func measure(_ type: UTType) -> DeviceArtwork? {
        let image = NSWorkspace.shared.icon(for: type)
        let n = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // NSBitmapImageRep pixel coordinates run from the top-left.
        func sample(_ x: Int, _ y: Int) -> (alpha: CGFloat, luma: CGFloat) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0) }
            return (c.alphaComponent, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
        }
        func isClear(_ x: Int, _ y: Int) -> Bool { sample(x, y).alpha < 0.5 }
        func isBezel(_ x: Int, _ y: Int) -> Bool { let s = sample(x, y); return s.alpha >= 0.5 && s.luma < 0.15 }
        func isScreen(_ x: Int, _ y: Int) -> Bool { let s = sample(x, y); return s.alpha >= 0.5 && s.luma >= 0.15 }

        let cx = n / 2
        guard let cy = [0.45, 0.4, 0.5, 0.35].map({ Int($0 * Double(n)) }).first(where: { isScreen(cx, $0) })
        else { return nil }

        var left = cx, right = cx
        while left > 0, isScreen(left - 1, cy) { left -= 1 }
        while right < n - 1, isScreen(right + 1, cy) { right += 1 }

        // Measure the height a quarter of the way across, not down the middle:
        // a MacBook's notch hangs into the top of the screen at the centre, and
        // the panel beside it (where the menu bar sits) is still screen.
        let vx = left + (right - left) / 4
        var top = cy, bottom = cy
        while top > 0, isScreen(vx, top - 1) { top -= 1 }
        while bottom < n - 1, isScreen(vx, bottom + 1) { bottom += 1 }

        var bezelLeft = left, bezelRight = right, bezelTop = top
        while bezelLeft > 0, isBezel(bezelLeft - 1, cy) { bezelLeft -= 1 }
        while bezelRight < n - 1, isBezel(bezelRight + 1, cy) { bezelRight += 1 }
        while bezelTop > 0, isBezel(vx, bezelTop - 1) { bezelTop -= 1 }

        // The notch, if any: dark pixels reaching down from the screen's top edge
        // at the centre. Kept so the preview can draw it over the wallpaper.
        var notchBottom = top
        while notchBottom < bottom, isBezel(cx, notchBottom) { notchBottom += 1 }
        var notch: CGRect?
        if notchBottom > top {
            var notchLeft = cx, notchRight = cx
            while notchLeft > left, isBezel(notchLeft - 1, top) { notchLeft -= 1 }
            while notchRight < right, isBezel(notchRight + 1, top) { notchRight += 1 }
            let w = notchRight - notchLeft + 1, h = notchBottom - top
            if w < (right - left) * 3 / 10, h < (bottom - top) / 10 {
                notch = CGRect(x: CGFloat(notchLeft) / CGFloat(n), y: CGFloat(top) / CGFloat(n),
                               width: CGFloat(w) / CGFloat(n), height: CGFloat(h) / CGFloat(n))
            }
        }
        let frame = ((left - bezelLeft) + (bezelRight - right)) / 2
        let bezelBottom = min(n - 1, bottom + frame)

        // The stand can have see-through details (a hinge cut-out on the Studio
        // Display), so take the lowest opaque row anywhere in a band around the
        // centre rather than walking down a single column.
        let band = stride(from: cx - n / 8, through: cx + n / 8, by: 2)
        var foot = bottom
        for y in stride(from: n - 1, to: bottom, by: -1) where band.contains(where: { !isClear($0, y) }) {
            foot = y
            break
        }

        // Reject anything that is not a plausible straight-on screen in a frame:
        // too small, no frame, or a frame that is really something else.
        let screenW = right - left + 1, screenH = bottom - top + 1
        let limit = n / 10
        guard screenW >= n * 2 / 5, screenH >= n / 5,
              frame > 0, frame < limit, top - bezelTop > 0, top - bezelTop < limit,
              isClear(max(bezelLeft - 2, 0), cy), isClear(min(bezelRight + 2, n - 1), cy)
        else { return nil }

        // A laptop's base is wider than its lid. Walk in from each edge of every
        // other row below the bezel to find how far it reaches past the sides.
        var widest = 0
        for y in stride(from: bezelBottom + 1, through: foot, by: 2) {
            var x = 0
            while x < bezelLeft, isClear(x, y) { x += 1 }
            var r = n - 1
            while r > bezelRight, isClear(r, y) { r -= 1 }
            widest = max(widest, bezelLeft - x, r - bezelRight)
        }

        let unit = CGFloat(n)
        return DeviceArtwork(
            image: image,
            screen: CGRect(x: CGFloat(left) / unit, y: CGFloat(top) / unit,
                           width: CGFloat(screenW) / unit, height: CGFloat(screenH) / unit),
            bezel: CGRect(x: CGFloat(bezelLeft) / unit, y: CGFloat(bezelTop) / unit,
                          width: CGFloat(bezelRight - bezelLeft + 1) / unit,
                          height: CGFloat(bezelBottom - bezelTop + 1) / unit),
            bottom: CGFloat(foot + 1) / unit,
            notch: notch,
            screenAspect: CGFloat(screenW) / CGFloat(screenH),
            overhang: CGFloat(widest) / CGFloat(bezelRight - bezelLeft + 1))
    }
}
