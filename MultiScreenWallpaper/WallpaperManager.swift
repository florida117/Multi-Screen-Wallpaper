import AppKit
import CoreImage

final class WallpaperManager: ObservableObject {
    @Published var sourceImage: NSImage?
    @Published var splitFractions: [CGFloat] = [0.5]
    @Published var statusMessage: String = ""
    @Published var isError: Bool = false

    private var sourceURL: URL?
    private let ciContext = CIContext()

    private let wallpaperOpts: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true
    ]

    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            setStatus("Failed to open image.", error: true)
            return
        }
        sourceImage = image
        sourceURL = url
        resetFractions()
        setStatus("Loaded: \(url.lastPathComponent)", error: false)
    }

    func applyWallpapers() {
        guard let url = sourceURL else { return }

        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard screens.count >= 2 else {
            setStatus("Only \(screens.count) display detected. Connect a second display.", error: true)
            return
        }

        // If the screen count changed since the image was loaded, re-space the cuts evenly.
        var fractions = splitFractions
        if fractions.count != screens.count - 1 {
            fractions = evenFractions(for: screens.count)
        }

        let cuts: [CGFloat] = [0] + fractions.sorted() + [1]
        let count = screens.count
        let base  = url.deletingPathExtension().lastPathComponent

        DispatchQueue.global(qos: .default).async {
            do {
                guard let ci = CIImage(contentsOf: url,
                                       options: [.applyOrientationProperty: true])
                else { throw WallpaperError.renderFailed }

                let ext = ci.extent
                let storageDir = try self.wallpaperStorageDirectory()
                var renderedWallpapers: [(screen: NSScreen, url: URL)] = []

                for (i, screen) in screens.enumerated() {
                    let x0      = ext.minX + ext.width * cuts[i]
                    let x1      = ext.minX + ext.width * cuts[i + 1]
                    let srcRect = CGRect(x: x0, y: ext.minY, width: x1 - x0, height: ext.height)
                    let name    = "\(base)_Screen\(i + 1).png"
                    let wURL    = try self.cropAndSave(ci: ci, srcRect: srcRect, screen: screen, name: name, storageDir: storageDir)
                    renderedWallpapers.append((screen: screen, url: wURL))
                }

                DispatchQueue.main.async {
                    do {
                        let ws = NSWorkspace.shared
                        for wallpaper in renderedWallpapers {
                            try ws.setDesktopImageURL(wallpaper.url, for: wallpaper.screen, options: self.wallpaperOpts)
                        }
                        try self.removeGeneratedWallpapers(in: storageDir,
                                                           keeping: Set(renderedWallpapers.map(\.url.lastPathComponent)))
                        self.setStatus("Applied to \(count) display\(count == 1 ? "" : "s").", error: false)
                    } catch {
                        self.setStatus(error.localizedDescription, error: true)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.setStatus(error.localizedDescription, error: true) }
            }
        }
    }

    // MARK: - Private

    private func resetFractions() {
        splitFractions = evenFractions(for: max(NSScreen.screens.count, 2))
    }

    private func evenFractions(for count: Int) -> [CGFloat] {
        (1..<count).map { CGFloat($0) / CGFloat(count) }
    }

    private func cropAndSave(ci: CIImage, srcRect: CGRect, screen: NSScreen, name: String, storageDir: URL) throws -> URL {
        let scale        = screen.backingScaleFactor
        let pixelW       = screen.frame.width  * scale
        let pixelH       = screen.frame.height * scale
        let screenAspect = pixelW / pixelH
        let srcAspect    = srcRect.width / srcRect.height

        // Center-crop the slice to the screen's exact aspect ratio.
        let cropRect: CGRect
        if srcAspect > screenAspect {
            let w = srcRect.height * screenAspect
            cropRect = CGRect(x: srcRect.minX + (srcRect.width - w) / 2,
                              y: srcRect.minY, width: w, height: srcRect.height)
        } else {
            let h = srcRect.width / screenAspect
            cropRect = CGRect(x: srcRect.minX,
                              y: srcRect.minY + (srcRect.height - h) / 2,
                              width: srcRect.width, height: h)
        }

        let processed = ci
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: pixelW / cropRect.width,
                                               y:      pixelH / cropRect.height))

        let url        = storageDir.appendingPathComponent(name)
        let colorSpace = ci.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        try ciContext.writePNGRepresentation(of: processed, to: url,
                                             format: .RGBA8, colorSpace: colorSpace,
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
