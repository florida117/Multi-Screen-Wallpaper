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
    @Published var splitFractions: [CGFloat] = [] { didSet { persistFractions() } }
    @Published var statusMessage: String = ""
    @Published var isError: Bool = false

    // Display arrangement, refreshed whenever the screen configuration changes.
    @Published private(set) var displayCount: Int = NSScreen.screens.count
    @Published private(set) var layout: DisplayLayout = DisplayLayout(arrangement: .row, axis: .horizontal, order: [])
    @Published private(set) var slots: [SpanSlot] = []
    @Published private(set) var unionBox: CGRect = .zero

    @Published private(set) var isProcessing: Bool = false
    @Published var autoReapply: Bool = true { didSet { UserDefaults.standard.set(autoReapply, forKey: Keys.autoReapply) } }

    private var sourceURL: URL?
    private var hasApplied = false
    private let ciContext = CIContext()

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
    }

    // MARK: - Public

    func loadImage(from url: URL) {
        // Use the same CIImage pipeline as apply so the preview honours EXIF
        // orientation exactly as the generated wallpaper will.
        guard let image = previewImage(from: url) else {
            setStatus("Failed to open image.", error: true)
            return
        }
        sourceImage = image
        sourceURL = url
        UserDefaults.standard.set(url.path, forKey: Keys.lastImagePath)
        resetFractions()
        setStatus("Loaded: \(url.lastPathComponent)", error: false)
    }

    func applyWallpapers() {
        guard let url = sourceURL else { return }

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
        var fractions = splitFractions.sorted()
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
                    defer { self.isProcessing = false }
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
                    self.isProcessing = false
                    self.setStatus(error.localizedDescription, error: true)
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
        refreshDisplays()
        // Keep the split lines consistent with the new arrangement.
        if layout.arrangement == .grid {
            if !splitFractions.isEmpty { splitFractions = [] }
        } else if splitFractions.count != max(displayCount - 1, 0) {
            splitFractions = WallpaperGeometry.evenFractions(count: max(displayCount, 1))
        }
        // macOS drops a spanned wallpaper when displays change; re-apply if asked.
        if autoReapply, hasApplied, sourceURL != nil {
            applyWallpapers()
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
        guard let path = defaults.string(forKey: Keys.lastImagePath),
              FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        guard let image = previewImage(from: url) else { return }

        sourceImage = image
        sourceURL = url

        if layout.arrangement != .grid,
           let saved = defaults.array(forKey: Keys.splitFractions) as? [Double],
           saved.count == max(displayCount - 1, 0) {
            splitFractions = saved.map { CGFloat($0) }
        } else {
            resetFractions()
        }
        setStatus("Restored: \(url.lastPathComponent)", error: false)
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

    private func setStatus(_ msg: String, error: Bool) {
        statusMessage = msg
        isError = error
    }

    enum WallpaperError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "Failed to render image slice." }
    }
}
