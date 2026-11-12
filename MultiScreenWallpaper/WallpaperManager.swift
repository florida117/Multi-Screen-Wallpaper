import AppKit
import CoreImage

/// One display's slot in the panorama, in span order. Consumed by the canvas
/// for previewing and by apply for rendering.
struct SpanSlot: Equatable {
    let name: String
    let aspect: CGFloat   // width / height, in points (scale-independent)
    let frame: CGRect     // global frame, for grid proportional mapping
    /// A laptop's own panel, drawn on the desk preview with a base, not a stand.
    let isBuiltIn: Bool
    /// The Core Graphics display ID, for looking up the device's own artwork.
    let displayID: CGDirectDisplayID?
}

/// Main-actor isolated: it drives the UI and talks to AppKit. The work that runs
/// in the background (decoding and rendering) lives in `nonisolated static`
/// helpers that touch none of its state.
@MainActor
final class WallpaperManager: ObservableObject {
    @Published var sourceImage: NSImage?
    /// A flat, downsampled raster of the source for SwiftUI previews. The source
    /// NSImage re-renders through Core Image every time it is drawn, which is
    /// far too slow for several live desk previews.
    @Published private(set) var sourceThumbnail: CGImage?
    /// The preset the current image and framing came from, if any.
    @Published private(set) var activePresetID: UUID?
    /// Interior split positions, always kept in ascending order. Drawing, hit
    /// testing, accessibility frames and rendering all index this array directly,
    /// so they only agree if the ordering invariant holds. Every writer preserves
    /// it: `evenFractions` is ordered, `CanvasNSView.setFraction` clamps between
    /// neighbours, and the restore path sorts what it reads back.
    @Published var splitFractions: [CGFloat] = [] { didSet { persistFractions() } }
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isError: Bool = false

    // MARK: Framing (zoom and pan)

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 4

    /// How far into the image the span is cropped. 1 uses the whole image, which
    /// is exactly the behaviour that existed before framing was added.
    @Published var zoom: CGFloat = 1 {
        didSet {
            // Assigning a property inside its own didSet does not run the observer
            // again, so clamp in place and carry on with the rest of the body.
            let limited = min(max(zoom, Self.minZoom), Self.maxZoom)
            if limited != zoom { zoom = limited }
            guard zoom != oldValue else { return }
            // A smaller zoom leaves less room to pan, so the offset may no longer
            // be reachable; pulling it back in keeps the image covering every screen.
            offset = WallpaperGeometry.clampOffset(offset, zoom: zoom)
            persistFraming()
        }
    }

    /// Pan, as a fraction of the full image measured from the centred position.
    @Published var offset: CGSize = .zero {
        didSet {
            let limited = WallpaperGeometry.clampOffset(offset, zoom: zoom)
            if limited != offset { offset = limited }   // does not re-run didSet
            guard offset != oldValue else { return }
            persistFraming()
        }
    }

    /// True when there is any room to pan — at fit, the whole image is already shown.
    var canPan: Bool { zoom > Self.minZoom }

    /// Whether the framing differs from "whole image, centred".
    var isFramed: Bool { zoom != Self.minZoom || offset != .zero }

    // MARK: Presets

    @Published private(set) var presets: [WallpaperPreset] = []

    // Display arrangement, refreshed whenever the screen configuration changes.
    @Published private(set) var displayCount: Int = NSScreen.screens.count
    @Published private(set) var layout: DisplayLayout = DisplayLayout(arrangement: .row, axis: .horizontal, order: [])
    @Published private(set) var slots: [SpanSlot] = []
    @Published private(set) var unionBox: CGRect = .zero

    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var isLoading: Bool = false

    /// True while either a decode or a render is running.
    var isBusy: Bool { isProcessing || isLoading }
    @Published var autoReapply: Bool = true { didSet { UserDefaults.standard.set(autoReapply, forKey: Keys.autoReapply) } }

    private var sourceURL: URL?
    /// The image most recently set as the wallpaper. Persisted, so a display
    /// change after a relaunch is still re-applied, and compared with the open
    /// image, so a reconfiguration never applies an image the user has only
    /// opened and not yet applied.
    private var appliedImagePath: String? {
        didSet { UserDefaults.standard.set(appliedImagePath, forKey: Keys.appliedImagePath) }
    }
    private let ciContext = CIContext()

    /// Identifies the most recent image load, so a slow decode that finishes late
    /// cannot overwrite a newer one.
    private var loadGeneration = 0
    /// Set when an apply is requested while one is already running, so the newest
    /// arrangement still gets applied once the in-flight render finishes.
    private var applyQueuedWhileBusy = false
    private var pendingReapply: Task<Void, Never>?

    private enum Keys {
        static let lastImagePath = "lastImagePath"
        static let splitFractions = "splitFractions"
        static let autoReapply = "autoReapply"
        static let zoom = "zoom"
        static let offsetX = "offsetX"
        static let offsetY = "offsetY"
        static let appliedImagePath = "appliedImagePath"
    }

    private let wallpaperOpts: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true
    ]

    init() {
        autoReapply = UserDefaults.standard.object(forKey: Keys.autoReapply) as? Bool ?? true
        appliedImagePath = UserDefaults.standard.string(forKey: Keys.appliedImagePath)
        let stored = PresetStore.load()
        presets = stored.presets
        if let setAside = stored.setAside {
            setStatus("Saved presets could not be read; the file was kept as \(setAside.lastPathComponent).",
                      error: true)
        }
        refreshDisplays()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        restoreLastSession()
    }

    deinit {
        // A pending re-apply holds only a weak reference, so it ends on its own.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    func loadImage(from url: URL) {
        loadImage(from: url, preset: nil)
    }

    /// `preset`, when given, has its splits and framing restored once the decode
    /// lands. It travels with this load rather than living in shared state, so a
    /// load that is superseded can never hand its preset to the one that replaced it.
    private func loadImage(from url: URL, preset: WallpaperPreset?) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        setStatus("Opening \(url.lastPathComponent)…", error: false)

        // Reading the file can block — see restoreLastSession for why — so the
        // decode stays off the main thread and the window keeps responding.
        let context = ciContext
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Uses the same CIImage pipeline as apply, so the preview honours EXIF
            // orientation exactly as the generated wallpaper will.
            let decoded = Self.decodePreview(from: url, context: context)

            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.isLoading = false
                guard let decoded else {
                    self.setStatus("Failed to open image.", error: true)
                    return
                }
                self.sourceImage = decoded.image
                self.sourceThumbnail = decoded.thumbnail
                self.activePresetID = preset?.id
                self.sourceURL = url
                UserDefaults.standard.set(url.path, forKey: Keys.lastImagePath)

                if let preset {
                    self.applyFraming(zoom: preset.zoom, offset: preset.offset)
                    // Splits from a different display arrangement cannot be honoured;
                    // fall back to the defaults for the displays actually attached.
                    if self.layout.arrangement != .grid,
                       preset.splitFractions.count == max(self.displayCount - 1, 0) {
                        self.splitFractions = preset.splitFractions.sorted()
                    } else {
                        self.resetFractions()
                    }
                    self.setStatus("Loaded preset “\(preset.name)”.", error: false)
                } else {
                    self.applyFraming(zoom: Self.minZoom, offset: .zero)
                    self.resetFractions()
                    self.setStatus("Loaded: \(url.lastPathComponent)", error: false)
                }
            }
        }
    }

    func applyWallpapers() {
        guard let url = sourceURL else { return }

        // Renders write to deterministic per-screen paths and the cleanup pass
        // deletes anything outside the current set, so two overlapping runs would
        // corrupt each other's output. Coalesce instead of running concurrently.
        guard !isProcessing else {
            applyQueuedWhileBusy = true
            return
        }

        let screensRaw = NSScreen.screens
        guard !screensRaw.isEmpty else {
            setStatus("No displays detected.", error: true)
            return
        }

        let layout = WallpaperGeometry.analyzeLayout(frames: screensRaw.map(\.frame))
        let orderedScreens = layout.order.map { screensRaw[$0] }
        let count = orderedScreens.count

        let fractions = splitFractions
        let base = url.deletingPathExtension().lastPathComponent
        let zoom = self.zoom
        let offset = self.offset
        // Snapshot each screen's geometry here on the main thread. NSScreen is
        // AppKit, and reading it live from the render queue could mix a mid-render
        // reconfiguration's frames with the layout captured above. A
        // reconfiguration schedules its own re-apply, which sees the new state.
        let frames = orderedScreens.map(\.frame)
        // Screens are matched up again by ID once rendering is done: an NSScreen
        // belongs on the main thread, and a display that has gone by then is
        // simply skipped — its removal schedules a re-apply of its own.
        let displayIDs = orderedScreens.map(Self.displayID(of:))
        let pixelSizes = orderedScreens.map {
            CGSize(width: ($0.frame.width * $0.backingScaleFactor).rounded(),
                   height: ($0.frame.height * $0.backingScaleFactor).rounded())
        }

        let context = ciContext
        isProcessing = true
        setStatus("Applying wallpaper to \(count) display\(count == 1 ? "" : "s")…", error: false)

        DispatchQueue.global(qos: .userInitiated).async {
            var applyDir: URL?
            do {
                guard let ci = CIImage(contentsOf: url,
                                       options: [.applyOrientationProperty: true])
                else { throw WallpaperError.renderFailed }

                // The same crops the desk preview shows, from the same function.
                let crops = WallpaperGeometry.displayCrops(
                    in: ci.extent, zoom: zoom, offset: offset,
                    arrangement: layout.arrangement, axis: layout.axis,
                    fractions: fractions, orderedFrames: frames,
                    aspects: pixelSizes.map { $0.width / $0.height })
                guard crops.count == count else { throw WallpaperError.renderFailed }

                let dir = try Self.makeApplyDirectory()
                applyDir = dir
                var renderedURLs: [URL] = []

                for i in 0..<count {
                    let wURL = dir.appendingPathComponent("\(base)_Screen\(i + 1).png")
                    try Self.cropAndSave(ci: ci, cropRect: crops[i], pixelSize: pixelSizes[i],
                                         to: wURL, context: context)
                    renderedURLs.append(wURL)
                }

                DispatchQueue.main.async {
                    defer { self.finishApply() }
                    do {
                        let ws = NSWorkspace.shared
                        let current = NSScreen.screens
                        for (id, wURL) in zip(displayIDs, renderedURLs) {
                            guard let id, let screen = current.first(where: { Self.displayID(of: $0) == id })
                            else { continue }
                            try ws.setDesktopImageURL(wURL, for: screen, options: self.wallpaperOpts)
                        }
                        try self.pruneRenderedWallpapers(keeping: dir)
                        self.appliedImagePath = url.path
                        self.setStatus("Applied to \(count) display\(count == 1 ? "" : "s").", error: false)
                    } catch {
                        self.setStatus(error.localizedDescription, error: true)
                    }
                }
            } catch {
                // Nothing from a failed render was ever set as a wallpaper, so its
                // partial output can go straight away.
                if let applyDir { try? FileManager.default.removeItem(at: applyDir) }
                DispatchQueue.main.async {
                    self.setStatus(error.localizedDescription, error: true)
                    self.finishApply()
                }
            }
        }
    }

    /// Reset split lines to the natural spacing for the current arrangement: each
    /// display gets a share of the image proportional to its own size, so the
    /// panorama lands at the same scale on every screen.
    func resetFractions() {
        splitFractions = defaultFractionsForCurrentLayout()
    }

    /// The default splits for the displays as currently arranged. `slots` is
    /// already in span order, which is what `defaultFractions` expects.
    private func defaultFractionsForCurrentLayout() -> [CGFloat] {
        WallpaperGeometry.defaultFractions(orderedFrames: slots.map(\.frame),
                                           arrangement: layout.arrangement,
                                           axis: layout.axis)
    }

    // MARK: - Framing

    /// Return to showing the whole image, centred.
    func resetFraming() {
        guard isFramed else { return }
        zoom = Self.minZoom
        offset = .zero
        setStatus("Framing reset to fit.", error: false)
    }

    /// Multiply the zoom, keeping it inside the supported range. Silent: a pinch
    /// emits a continuous stream of these, and announcing each one would flood
    /// VoiceOver. Callers announce once the gesture settles.
    func zoomBy(_ factor: CGFloat) {
        zoom = zoom * factor
    }

    /// Pan by a fraction of the *visible* region, so a drag tracks the cursor at
    /// every zoom level instead of accelerating as you zoom in. Silent, as above.
    func pan(dx: CGFloat, dy: CGFloat) {
        guard canPan else { return }
        offset = CGSize(width: offset.width + dx / zoom, height: offset.height + dy / zoom)
    }

    /// Discrete zoom step from a menu command or keyboard shortcut, announced.
    func nudgeZoom(_ factor: CGFloat) {
        let before = zoom
        zoomBy(factor)
        Accessibility.announce(zoom == before ? "Zoom limit reached." : framingSummary)
    }

    /// Discrete pan step from a menu command or keyboard shortcut, announced.
    func nudgePan(dx: CGFloat, dy: CGFloat) {
        guard canPan else {
            Accessibility.announce("Zoom in before panning.")
            return
        }
        let before = offset
        pan(dx: dx, dy: dy)
        Accessibility.announce(offset == before ? "Edge of the image reached." : framingSummary)
    }

    /// Spoken description of the current zoom and pan.
    var framingSummary: String {
        guard isFramed else { return "Showing the whole image." }
        let pct = Int((zoom * 100).rounded())
        guard canPan else { return "Zoom \(pct) percent." }
        let limit = WallpaperGeometry.maxOffset(zoom: zoom)
        guard limit > 0 else { return "Zoom \(pct) percent." }
        // Report position within the pannable range, where 50 percent is centred.
        let h = Accessibility.percent((offset.width / limit + 1) / 2)
        let v = Accessibility.percent((1 - offset.height / limit) / 2)
        return "Zoom \(pct) percent. Horizontal \(h) percent, vertical \(v) percent."
    }

    // MARK: - Presets

    /// The open image's file name, for display.
    var sourceFileName: String? { sourceURL?.lastPathComponent }

    /// A sensible default when naming a new preset: the image's own filename.
    var suggestedPresetName: String {
        sourceURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// Capture the current image, splits and framing under `name`.
    func savePreset(named name: String) {
        guard let url = sourceURL else {
            setStatus("Open an image before saving a preset.", error: true)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed

        let preset = WallpaperPreset(name: finalName,
                                     imagePath: url.path,
                                     splitFractions: splitFractions,
                                     zoom: zoom,
                                     offset: offset)
        // Saving under an existing name replaces it, so re-saving after a tweak
        // updates the preset instead of silently accumulating duplicates.
        if let idx = presets.firstIndex(where: { $0.name == finalName }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        activePresetID = preset.id
        persistPresets()
        setStatus("Saved preset “\(finalName)”.", error: false)
    }

    /// Restore a preset's image, splits and framing. The wallpaper is not applied;
    /// the user still confirms with Apply, so loading a preset is never destructive.
    func loadPreset(_ preset: WallpaperPreset) {
        guard preset.isAvailable else {
            setStatus("“\(preset.name)” is missing its image (\(preset.imageName)).", error: true)
            return
        }

        // The decode is asynchronous, so the preset rides along and is applied when
        // the image lands — otherwise loadImage's reset would overwrite it.
        loadImage(from: preset.imageURL, preset: preset)
    }

    func deletePreset(_ preset: WallpaperPreset) {
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        persistPresets()
        setStatus("Deleted preset “\(preset.name)”.", error: false)
    }

    func renamePreset(_ preset: WallpaperPreset, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx].name = trimmed
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistPresets()
    }

    private func persistPresets() {
        if let error = PresetStore.save(presets) {
            setStatus("Could not save presets: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - Display changes

    @objc private func screensChanged() {
        let previous = (count: displayCount, arrangement: layout.arrangement, spans: slotSpans)
        refreshDisplays()
        // Keep the split lines consistent with the new arrangement. The count alone
        // is not enough: swapping a narrow and a wide display, or turning a row into
        // a column, keeps the count but makes the old splits hand each display the
        // wrong share. Moving displays without changing their order or size keeps
        // the user's splits.
        if layout.arrangement == .grid {
            if !splitFractions.isEmpty { splitFractions = [] }
        } else if splitFractions.count != max(displayCount - 1, 0)
                    || previous.arrangement != layout.arrangement
                    || previous.spans != slotSpans {
            splitFractions = defaultFractionsForCurrentLayout()
        }
        // Connecting or removing a display rearranges the whole canvas; say so,
        // since a sighted user sees it happen and a VoiceOver user would not.
        if previous.count != displayCount || previous.arrangement != layout.arrangement {
            Accessibility.announce(arrangementSummary)
        }
        // macOS drops a spanned wallpaper when displays change; re-apply if asked,
        // but only the image that is actually on the wall.
        if autoReapply, let path = sourceURL?.path, path == appliedImagePath {
            scheduleReapply()
        }
    }

    /// Reconfiguring displays emits a burst of notifications — connecting a single
    /// monitor can fire several as the arrangement settles. Coalesce them so one
    /// apply runs against the final layout instead of one per notification.
    private func scheduleReapply() {
        pendingReapply?.cancel()
        pendingReapply = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingReapply = nil
            self.applyWallpapers()
        }
    }

    /// Clear the in-flight flag and run whatever was requested while we were busy.
    private func finishApply() {
        isProcessing = false
        if applyQueuedWhileBusy {
            applyQueuedWhileBusy = false
            scheduleReapply()
        }
    }

    /// Spoken description of the current display arrangement.
    var arrangementSummary: String {
        let noun = "\(displayCount) display\(displayCount == 1 ? "" : "s")"
        switch layout.arrangement {
        case .row where displayCount > 1: return "\(noun) detected, arranged in a row."
        case .column:                     return "\(noun) detected, arranged in a column."
        case .grid:                       return "\(noun) detected, arranged in a grid."
        default:                          return "\(noun) detected."
        }
    }

    /// Each display's extent along the split axis, in span order — what the
    /// default splits are computed from.
    private var slotSpans: [CGFloat] {
        slots.map { layout.axis == .horizontal ? $0.frame.width : $0.frame.height }
    }

    /// The display frame the canvas should use when previewing slot `i`'s crop.
    /// Falls back to the union box, which makes `arrangedCrop` centre the crop —
    /// the right answer while the split count briefly outruns the known displays.
    func frame(forSlot i: Int) -> CGRect {
        i < slots.count ? slots[i].frame : unionBox
    }

    /// The Core Graphics display ID behind `screen`.
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func refreshDisplays() {
        let screensRaw = NSScreen.screens
        let frames = screensRaw.map(\.frame)
        displayCount = screensRaw.count
        let l = WallpaperGeometry.analyzeLayout(frames: frames)
        layout = l
        unionBox = WallpaperGeometry.unionBox(frames)
        slots = l.order.map { idx in
            let s = screensRaw[idx]
            let displayID = Self.displayID(of: s)
            return SpanSlot(name: s.localizedName,
                            aspect: s.frame.width / max(s.frame.height, 1),
                            frame: s.frame,
                            isBuiltIn: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                            displayID: displayID)
        }
    }

    // MARK: - Desk preview

    /// Each display's share of the visible image along the split axis, in span
    /// order; empty for a grid, which is mapped by position rather than shares.
    var slotShares: [CGFloat] {
        let fractions = WallpaperGeometry.effectiveFractions(splitFractions, orderedFrames: slots.map(\.frame),
                                                             arrangement: layout.arrangement, axis: layout.axis)
        guard layout.arrangement != .grid, !slots.isEmpty else { return [] }
        let cuts: [CGFloat] = [0] + fractions + [1]
        return (0..<cuts.count - 1).map { cuts[$0 + 1] - cuts[$0] }
    }

    /// What each display will show, in span order, as unit rectangles of the
    /// source image (0...1, Y-up). Computed by the same function apply renders
    /// with, so the desk preview cannot disagree with the result.
    var deskCrops: [CGRect] {
        guard let size = sourceImage?.size, size.width > 0, size.height > 0 else { return [] }
        let crops = WallpaperGeometry.displayCrops(
            in: CGRect(origin: .zero, size: size), zoom: zoom, offset: offset,
            arrangement: layout.arrangement, axis: layout.axis,
            fractions: splitFractions, orderedFrames: slots.map(\.frame),
            aspects: slots.map(\.aspect))
        return crops.map {
            CGRect(x: $0.minX / size.width, y: $0.minY / size.height,
                   width: $0.width / size.width, height: $0.height / size.height)
        }
    }

    // MARK: - Persistence

    private func persistFractions() {
        UserDefaults.standard.set(splitFractions.map(Double.init), forKey: Keys.splitFractions)
    }

    private func persistFraming() {
        let defaults = UserDefaults.standard
        defaults.set(Double(zoom), forKey: Keys.zoom)
        defaults.set(Double(offset.width), forKey: Keys.offsetX)
        defaults.set(Double(offset.height), forKey: Keys.offsetY)
    }

    /// Set zoom and pan together. Zoom goes first because it determines how far the
    /// offset is allowed to travel — assigning them the other way round would clamp
    /// the offset against the previous zoom.
    private func applyFraming(zoom newZoom: CGFloat, offset newOffset: CGSize) {
        zoom = min(max(newZoom, Self.minZoom), Self.maxZoom)
        offset = WallpaperGeometry.clampOffset(newOffset, zoom: zoom)
    }

    private func restoreLastSession() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Keys.lastImagePath) else { return }
        let url = URL(fileURLWithPath: path)
        // Read the saved splits now: the decode below is asynchronous, and
        // anything that touches splitFractions in the meantime would overwrite
        // the stored value before we got to read it.
        let savedFractions = (defaults.array(forKey: Keys.splitFractions) as? [Double])?
            .map { CGFloat($0) }.sorted()
        let savedZoom = (defaults.object(forKey: Keys.zoom) as? Double).map { CGFloat($0) } ?? Self.minZoom
        let savedOffset = CGSize(width:  CGFloat(defaults.double(forKey: Keys.offsetX)),
                                 height: CGFloat(defaults.double(forKey: Keys.offsetY)))

        // Opening the file can block for a long time — a cloud-backed file has to
        // be materialised first, and an unsandboxed app hitting a protected folder
        // waits on the system's permission prompt. On the main thread that stalls
        // launch before the window exists, so the restore happens in the
        // background and populates the canvas once it arrives.
        let generation = loadGeneration
        let context = ciContext

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard FileManager.default.fileExists(atPath: path),
                  let decoded = Self.decodePreview(from: url, context: context) else { return }

            DispatchQueue.main.async {
                // Drop the restore if the user opened something else meanwhile.
                guard let self, generation == self.loadGeneration else { return }
                self.sourceImage = decoded.image
                self.sourceThumbnail = decoded.thumbnail
                self.sourceURL = url
                self.applyFraming(zoom: savedZoom, offset: savedOffset)

                if self.layout.arrangement != .grid,
                   let saved = savedFractions, saved.count == max(self.displayCount - 1, 0) {
                    self.splitFractions = saved
                } else {
                    self.resetFractions()
                }
                // Keep an error from launch (unreadable presets) on screen rather
                // than replacing it with routine news.
                if !self.isError {
                    self.setStatus("Restored: \(url.lastPathComponent)", error: false)
                }
            }
        }
    }

    // MARK: - Rendering

    /// The full-resolution preview image plus a flat thumbnail of it, both from
    /// the same CIImage pipeline as apply so they honour EXIF orientation alike.
    nonisolated private static func decodePreview(from url: URL, context: CIContext)
        -> (image: NSImage, thumbnail: CGImage?)? {
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        // 4096 on the long side keeps a 4× zoom across three displays sharp in the
        // small desk previews, at about 16 MB for a 4:1 panorama.
        let longSide = max(ci.extent.width, ci.extent.height)
        let scale = longSide > 0 ? min(1, 4096 / longSide) : 1
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let thumbnail = context.createCGImage(scaled, from: scaled.extent.integral)
        return (image, thumbnail)
    }

    /// Scale `cropRect` of the source to exactly `pixelSize` and write it as a PNG.
    nonisolated private static func cropAndSave(ci: CIImage, cropRect: CGRect, pixelSize: CGSize,
                                                to url: URL, context: CIContext) throws {
        let pixelW = pixelSize.width, pixelH = pixelSize.height
        guard cropRect.width > 0, cropRect.height > 0, pixelW > 0, pixelH > 0 else {
            throw WallpaperError.renderFailed
        }

        // Resample the clamped image and crop afterwards, to exactly the output
        // pixels. Cropping first would leave transparency just outside the crop,
        // and the scale's linear filter would blend it into the outermost rows and
        // columns — a faint dark line at every seam between displays.
        let processed = ci
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: pixelW / cropRect.width,
                                               y:      pixelH / cropRect.height))
            .cropped(to: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // PNG output needs an RGB space. CMYK and grayscale sources (print JPEGs,
        // greyscale scans) carry a space Core Image cannot write as RGBA, so they
        // fall back to sRGB. Wide-gamut (e.g. Display P3) sources keep their space
        // at 16-bit to avoid banding.
        let colorSpace: CGColorSpace
        if let source = ci.colorSpace, source.model == .rgb {
            colorSpace = source
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let format: CIFormat = colorSpace.isWideGamutRGB ? .RGBA16 : .RGBA8

        try context.writePNGRepresentation(of: processed, to: url,
                                             format: format, colorSpace: colorSpace,
                                             options: [:])
    }

    // MARK: - Rendered file storage

    /// How many applies keep their rendered files, the current one included.
    /// `setDesktopImageURL` changes only the current Space, so other Spaces can
    /// still point at an earlier apply's files, and deleting those would blank
    /// them. Keeping a few recent sets covers that without growing forever; a
    /// Space left on an older set than this falls back to the system default.
    nonisolated private static let retainedApplies = 5

    nonisolated private static func renderedWallpapersDirectory() throws -> URL {
        let dir = try AppSupport.directory().appendingPathComponent("Rendered", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A new folder for one apply. A fresh path each time matters: the wallpaper
    /// agent caches by URL and can ignore a set to the URL it already shows, so
    /// re-applying after moving a split would otherwise leave the old slice up.
    nonisolated private static func makeApplyDirectory() throws -> URL {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        // Zero-padded so name order is chronological order; the suffix only
        // guards against two applies landing in the same millisecond.
        let name = String(format: "%015lld-", millis) + UUID().uuidString.prefix(8)
        let dir = try renderedWallpapersDirectory().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Drop apply folders beyond the newest `retainedApplies`, never `current`.
    private func pruneRenderedWallpapers(keeping current: URL) throws {
        let fileManager = FileManager.default
        let older = try fileManager
            .contentsOfDirectory(at: Self.renderedWallpapersDirectory(),
                                 includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                      && $0.lastPathComponent != current.lastPathComponent }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
        for url in older.dropFirst(Self.retainedApplies - 1) {
            try fileManager.removeItem(at: url)
        }

        // Before per-apply folders, renders sat loose in the storage directory.
        // Treat them as the oldest set: kept until enough newer applies exist that
        // they would have been pruned anyway. Everything png/heic directly in that
        // directory was written by an apply, so it is safe to remove.
        guard older.count >= Self.retainedApplies - 1 else { return }
        let legacy = try fileManager.contentsOfDirectory(at: AppSupport.directory(),
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])
        for url in legacy where ["png", "heic"].contains(url.pathExtension.lowercased()) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Update the status bar and speak the change. The status bar is the only
    /// feedback for loads, applies and errors, so without an announcement those
    /// outcomes are silent for VoiceOver users.
    func setStatus(_ msg: String, error: Bool) {
        statusMessage = msg
        isError = error
        Accessibility.announce(msg, priority: error ? .high : .medium)
    }

    enum WallpaperError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "Failed to render image slice." }
    }
}
