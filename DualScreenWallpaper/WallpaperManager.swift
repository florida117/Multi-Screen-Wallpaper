import AppKit
import CoreImage

final class WallpaperManager: ObservableObject {
    @Published var sourceImage: NSImage?
    @Published var splitFraction: CGFloat = 0.5
    @Published var statusMessage: String = ""
    @Published var isError: Bool = false

    private var sourceURL: URL?
    private let ciContext = CIContext()

    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            setStatus("Failed to open image.", error: true)
            return
        }
        sourceImage = image
        sourceURL = url
        splitFraction = 0.5
        setStatus("Loaded: \(url.lastPathComponent)", error: false)
    }

    func applyWallpapers() {
        guard let url = sourceURL else { return }

        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard screens.count >= 2 else {
            setStatus("Only \(screens.count) display detected. Connect a second display.", error: true)
            return
        }

        let fraction = splitFraction
        let screen0  = screens[0]
        let screen1  = screens[1]
        let label    = "\(screen0.localizedName) and \(screen1.localizedName)"
        let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: false
        ]

        DispatchQueue.global(qos: .default).async {
            do {
                // CIImage is thread-safe. .applyOrientationProperty corrects JPEG/HEIC
                // images that store rotation in EXIF metadata rather than pixel data.
                guard let ci = CIImage(contentsOf: url,
                                       options: [.applyOrientationProperty: true])
                else { throw WallpaperError.renderFailed }

                let ext      = ci.extent
                let leftSrc  = CGRect(x: ext.minX,
                                      y: ext.minY,
                                      width:  ext.width * fraction,
                                      height: ext.height)
                let rightSrc = CGRect(x: ext.minX + ext.width * fraction,
                                      y: ext.minY,
                                      width:  ext.width * (1 - fraction),
                                      height: ext.height)

                let base     = url.deletingPathExtension().lastPathComponent
                let leftURL  = try self.cropAndSave(ci: ci, srcRect: leftSrc,  screen: screen0, name: "\(base)_Left.png")
                let rightURL = try self.cropAndSave(ci: ci, srcRect: rightSrc, screen: screen1, name: "\(base)_Right.png")

                let ws = NSWorkspace.shared
                try ws.setDesktopImageURL(leftURL,  for: screen0, options: opts)
                try ws.setDesktopImageURL(rightURL, for: screen1, options: opts)

                DispatchQueue.main.async { self.setStatus("Applied to \(label).", error: false) }
            } catch {
                DispatchQueue.main.async { self.setStatus(error.localizedDescription, error: true) }
            }
        }
    }

    // MARK: - Private

    private func cropAndSave(ci: CIImage, srcRect: CGRect, screen: NSScreen, name: String) throws -> URL {
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

        // Crop → translate to origin → scale to exact screen pixel dimensions.
        // CIImage operations are lazy; no pixels are touched until writePNGRepresentation.
        let processed = ci
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: pixelW / cropRect.width,
                                               y:      pixelH / cropRect.height))

        let url        = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let colorSpace = ci.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        // writePNGRepresentation produces a standard top-down PNG with no manual flip needed.
        try ciContext.writePNGRepresentation(of: processed, to: url,
                                             format: .RGBA8, colorSpace: colorSpace)
        return url
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
