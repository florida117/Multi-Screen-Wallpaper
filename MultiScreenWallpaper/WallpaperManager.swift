import AppKit
import CoreImage

/// One display's slot in the panorama, in span order. Consumed by the canvas
/// for previewing and by apply for rendering.
struct SpanSlot: Equatable {
    let name: String
    let aspect: CGFloat   // width / height, in points (scale-independent)
    let frame: CGRect     // global frame, for grid proportional mapping
}

final class WallpaperManager: ObservableObject {
    @Published var sourceImage: NSImage?
    /// Interior split positions, always kept in ascending order. Drawing, hit
    /// testing, accessibility frames and rendering all index this array directly,
    /// so they only agree if the ordering invariant holds. Every writer preserves
    /// it: `evenFractions` is ordered, `CanvasNSView.setFraction` clamps between
    /// neighbours, and the restore path sorts what it reads back.
    @Published var splitFractions: [CGFloat] = [] { didSet { persistFractions() } }
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isError: Bool = false

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
    private var hasApplied = false
    private let ciContext = CIContext()

    /// Identifies the most recent image load, so a slow decode that finishes late
    /// cannot overwrite a newer one.
    private var loadGeneration = 0
    /// Set when an apply is requested while one is already running, so the newest
    /// arrangement still gets applied once the in-flight render finishes.
    private var applyQueuedWhileBusy = false
    private var pendingReapply: DispatchWorkItem?

    private enum Keys {
        static let lastImagePath = "lastImagePath"
        static let splitFractions = "splitFractions"
        static let autoReapply = "autoReapply"
    }

    private let wallpaperOpts: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true
    ]

    init() {
        autoReapply = UserDefaults.standard.object(forKey: Keys.autoReapply) as? Bool ?? true
        refreshDisplays()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        restoreLastSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingReapply?.cancel()
    }

    // MARK: - Public

    func loadImage(from url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        setStatus("Opening \(url.lastPathComponent)…", error: false)

        // Reading the file can block — see restoreLastSession for why — so the
        // decode stays off the main thread and the window keeps responding.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Uses the same CIImage pipeline as apply, so the preview honours EXIF
            // orientation exactly as the generated wallpaper will.
            let image = self?.previewImage(from: url)

            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.isLoading = false
                guard let image else {
                    self.setStatus("Failed to open image.", error: true)
                    return
                }
                self.sourceImage = image
                self.sourceURL = url
                UserDefaults.standard.set(url.path, forKey: Keys.lastImagePath)
                self.resetFractions()
                self.setStatus("Loaded: \(url.lastPathComponent)", error: false)
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

        let frames = screensRaw.map(\.frame)
        let layout = WallpaperGeometry.analyzeLayout(frames: frames)
        let orderedScreens = layout.order.map { screensRaw[$0] }
        let count = orderedScreens.count

        // Split fractions apply only to a row/column; a grid maps by position.
        var fractions = splitFractions
        if layout.arrangement == .grid {
            fractions = []
        } else if fractions.count != count - 1 {
            fractions = WallpaperGeometry.evenFractions(count: count)
        }
        let cuts: [CGFloat] = [0] + fractions + [1]
        let axis = layout.axis
        let arrangement = layout.arrangement
        let union = WallpaperGeometry.unionBox(frames)
        let base = url.deletingPathExtension().lastPathComponent

        isProcessing = true
        setStatus("Applying wallpaper to \(count) display\(count == 1 ? "" : "s")…", error: false)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let ci = CIImage(contentsOf: url,
                                       options: [.applyOrientationProperty: true])
                else { throw WallpaperError.renderFailed }

                let ext = ci.extent
                let storageDir = try self.wallpaperStorageDirectory()
                var renderedWallpapers: [(screen: NSScreen, url: URL)] = []

                for (i, screen) in orderedScreens.enumerated() {
                    let srcRect: CGRect
                    if arrangement == .grid {
                        srcRect = WallpaperGeometry.proportionalRect(in: ext, screenFrame: screen.frame, unionBox: union)
                    } else {
                        srcRect = WallpaperGeometry.sliceRect(in: ext, axis: axis, cuts: cuts, index: i)
                    }
                    let name = "\(base)_Screen\(i + 1).png"
                    let wURL = try self.cropAndSave(ci: ci, srcRect: srcRect, screen: screen, name: name, storageDir: storageDir)
                    renderedWallpapers.append((screen: screen, url: wURL))
                }

                DispatchQueue.main.async {
                    defer { self.finishApply() }
                    do {
                        let ws = NSWorkspace.shared
                        for wallpaper in renderedWallpapers {
                            try ws.setDesktopImageURL(wallpaper.url, for: wallpaper.screen, options: self.wallpaperOpts)
                        }
                        try self.removeGeneratedWallpapers(in: storageDir,
                                                           keeping: Set(renderedWallpapers.map(\.url.lastPathComponent)))
                        self.hasApplied = true
                        self.setStatus("Applied to \(count) display\(count == 1 ? "" : "s").", error: false)
                    } catch {
                        self.setStatus(error.localizedDescription, error: true)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.setStatus(error.localizedDescription, error: true)
                    self.finishApply()
                }
            }
        }
    }

    /// Reset split lines to an even spacing for the current arrangement.
    func resetFractions() {
        if layout.arrangement == .grid {
            splitFractions = []
        } else {
            splitFractions = WallpaperGeometry.evenFractions(count: max(displayCount, 1))
        }
    }

    // MARK: - Display changes

    @objc private func screensChanged() {
        let previous = (count: displayCount, arrangement: layout.arrangement)
        refreshDisplays()
        // Keep the split lines consistent with the new arrangement.
        if layout.arrangement == .grid {
            if !splitFractions.isEmpty { splitFractions = [] }
        } else if splitFractions.count != max(displayCount - 1, 0) {
            splitFractions = WallpaperGeometry.evenFractions(count: max(displayCount, 1))
        }
        // Connecting or removing a display rearranges the whole canvas; say so,
        // since a sighted user sees it happen and a VoiceOver user would not.
        if previous.count != displayCount || previous.arrangement != layout.arrangement {
            Accessibility.announce(arrangementSummary)
        }
        // macOS drops a spanned wallpaper when displays change; re-apply if asked.
        if autoReapply, hasApplied, sourceURL != nil {
            scheduleReapply()
        }
    }

    /// Reconfiguring displays emits a burst of notifications — connecting a single
    /// monitor can fire several as the arrangement settles. Coalesce them so one
    /// apply runs against the final layout instead of one per notification.
    private func scheduleReapply() {
        pendingReapply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReapply = nil
            self?.applyWallpapers()
        }
        pendingReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
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

    private func refreshDisplays() {
        let screensRaw = NSScreen.screens
        let frames = screensRaw.map(\.frame)
        displayCount = screensRaw.count
        let l = WallpaperGeometry.analyzeLayout(frames: frames)
        layout = l
        unionBox = WallpaperGeometry.unionBox(frames)
        slots = l.order.map { idx in
            let s = screensRaw[idx]
            return SpanSlot(name: s.localizedName,
                            aspect: s.frame.width / max(s.frame.height, 1),
                            frame: s.frame)
        }
    }

    // MARK: - Persistence

    private func persistFractions() {
        UserDefaults.standard.set(splitFractions.map(Double.init), forKey: Keys.splitFractions)
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

        // Opening the file can block for a long time — a cloud-backed file has to
        // be materialised first, and an unsandboxed app hitting a protected folder
        // waits on the system's permission prompt. On the main thread that stalls
        // launch before the window exists, so the restore happens in the
        // background and populates the canvas once it arrives.
        let generation = loadGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard FileManager.default.fileExists(atPath: path),
                  let image = self?.previewImage(from: url) else { return }

            DispatchQueue.main.async {
                // Drop the restore if the user opened something else meanwhile.
                guard let self, generation == self.loadGeneration else { return }
                self.sourceImage = image
                self.sourceURL = url

                if self.layout.arrangement != .grid,
                   let saved = savedFractions, saved.count == max(self.displayCount - 1, 0) {
                    self.splitFractions = saved
                } else {
                    self.resetFractions()
                }
                self.setStatus("Restored: \(url.lastPathComponent)", error: false)
            }
        }
    }

    // MARK: - Rendering

    private func previewImage(from url: URL) -> NSImage? {
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func cropAndSave(ci: CIImage, srcRect: CGRect, screen: NSScreen, name: String, storageDir: URL) throws -> URL {
        let scale  = screen.backingScaleFactor
        let pixelW = screen.frame.width  * scale
        let pixelH = screen.frame.height * scale

        // Center-crop the slice to the screen's exact pixel aspect ratio.
        let cropRect = WallpaperGeometry.centerCrop(srcRect, toAspect: pixelW / pixelH)

        let processed = ci
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: pixelW / cropRect.width,
                                               y:      pixelH / cropRect.height))

        let url = storageDir.appendingPathComponent(name)

        // Preserve wide-gamut (e.g. Display P3) sources at 16-bit to avoid banding;
        // fall back to 8-bit sRGB-class output otherwise.
        let sourceColorSpace = ci.colorSpace
        let wideGamut = sourceColorSpace?.isWideGamutRGB ?? false
        let colorSpace = sourceColorSpace ?? CGColorSpaceCreateDeviceRGB()
        let format: CIFormat = wideGamut ? .RGBA16 : .RGBA8

        try ciContext.writePNGRepresentation(of: processed, to: url,
                                             format: format, colorSpace: colorSpace,
                                             options: [:])
        return url
    }

    private func wallpaperStorageDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let storageDir = appSupport.appendingPathComponent("MultiScreenWallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        return storageDir
    }

    private func removeGeneratedWallpapers(in storageDir: URL, keeping filenamesToKeep: Set<String>) throws {
        // storageDir is the app's own Application Support subdirectory, so every
        // png/heic here was written by a previous apply and is safe to prune.
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(at: storageDir,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])
        for url in urls
        where ["png", "heic"].contains(url.pathExtension.lowercased())
            && !filenamesToKeep.contains(url.lastPathComponent) {
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
