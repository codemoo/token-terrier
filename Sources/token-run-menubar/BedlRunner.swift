import AppKit
import SwiftUI
import TokenUsageCore

/// Backing store for the bundled menu-bar Bedlington Terrier sprite. `MenuBarExtra`'s label
/// scene treats `Image(nsImage:)` as having an intrinsic point size matching
/// `NSImage.size` and ignores SwiftUI's `.frame(...)`, which is why we mutate
/// `NSImage.size` directly here.
@MainActor
final class BedlFrames {
    static let shared = BedlFrames()

    private let aspectRatio: CGFloat
    private let images: [NSImage]
    private let idleImage: NSImage?

    var frameCount: Int { images.count }

    private init() {
        let initial = Self.loadFrames()
        self.images = initial.images
        self.idleImage = initial.idleImage
        self.aspectRatio = initial.aspectRatio
    }

    /// SwiftUI-friendly wrapper. Recomputed each access so SwiftUI sees a new
    /// `Image` value when the underlying NSImage was resized.
    func image(at idx: Int) -> Image {
        guard !images.isEmpty else { return Image(systemName: "pawprint.fill") }
        let clamped = idx % images.count
        return Image(nsImage: images[clamped]).renderingMode(.original)
    }

    func standingImage() -> Image {
        if let idleImage {
            return Image(nsImage: idleImage).renderingMode(.original)
        }
        return image(at: 0)
    }

    /// Apply a uniform menu-bar height (in points) to every frame, preserving
    /// the bundled sprite's aspect ratio. Idempotent — call any time the user
    /// moves the "외관" slider.
    func setHeight(_ height: CGFloat) {
        let size = NSSize(width: height * aspectRatio, height: height)
        for img in images where img.size != size {
            img.size = size
        }
        if let idleImage, idleImage.size != size {
            idleImage.size = size
        }
    }

    /// Loads all `bedl-*.png` frames from the menu-bar app bundle.
    /// Falls back to a single SF Symbol if the resource bundle isn't found
    /// — should never happen in shipped builds but keeps dev mode runnable.
    private static func loadFrames() -> (images: [NSImage], idleImage: NSImage?, aspectRatio: CGFloat) {
        let catalog = loadFrameCatalog()
        let frames = orderedFrameURLs(from: catalog).compactMap { loadTemplateFrame(from: $0) }
        let idleImage = catalog[idleFrameNumber].flatMap { loadTemplateFrame(from: $0) }
        if frames.isEmpty {
            let placeholder = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil) ?? NSImage()
            return (images: [placeholder], idleImage: placeholder, aspectRatio: 1.0)
        }
        let firstSize = frames[0].size
        let aspectRatio = firstSize.height > 0 ? firstSize.width / firstSize.height : 1.0
        return (images: frames, idleImage: idleImage, aspectRatio: aspectRatio)
    }

    private static let idleFrameNumber = 8

    /// Expanded reversed gallop cycle. Some support/push frames are reused to
    /// give the gather phase more in-betweens without holding the exact same
    /// drawing twice in a row. The loop boundary remains the smooth
    /// `bedl-4 -> bedl-6` extended-flight transition.
    private static let preferredRunOrder = [6, 5, 2, 1, 7, 8, 3, 8, 7, 1, 2, 5, 6, 4]

    /// SwiftPM's auto-generated `Bundle.module` accessor expects the resource
    /// bundle to sit *next to* `Bundle.main`, which is true when we run the
    /// raw executable out of `.build/release/` but not when we wrap it in a
    /// `.app` (where it sensibly lives under `Contents/Resources/`). Look in
    /// both places so the sprite works in dev and shipping builds alike.
    private static func loadFrameCatalog() -> [Int: URL] {
        for bundle in BedlResourceBundle.candidateBundles {
            let catalog = frameCatalog(from: bundle.urls(forResourcesWithExtension: "png", subdirectory: "BedlFrames") ?? [])
            if !catalog.isEmpty { return catalog }
        }
        // Fallback: the dev-mode auto-generated bundle accessor.
        return frameCatalog(from: Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: "BedlFrames") ?? [])
    }

    private static func frameCatalog(from urls: [URL]) -> [Int: URL] {
        let numbered = urls.compactMap { url -> (Int, URL)? in
            guard let number = frameNumber(from: url) else { return nil }
            return (number, url)
        }
        return Dictionary(uniqueKeysWithValues: numbered.map { ($0.0, $0.1) })
    }

    private static func orderedFrameURLs(from catalog: [Int: URL]) -> [URL] {
        var ordered = preferredRunOrder.compactMap { catalog[$0] }

        let known = Set(preferredRunOrder)
        ordered += catalog
            .filter { !known.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map(\.value)
        return ordered
    }

    private static func frameNumber(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("bedl-") else { return nil }
        return Int(name.dropFirst("bedl-".count))
    }

    private static func loadTemplateFrame(from url: URL) -> NSImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let mask = img.bedlSilhouetteTemplateMask()
        mask.isTemplate = false
        return mask
    }
}

private extension NSImage {
    /// The bundled runner frames are RGB PNGs whose "transparent" area was
    /// exported as a light checkerboard. AppKit template images use alpha as
    /// the icon shape, so convert light pixels to transparent and keep the
    /// dark Bedlington silhouette opaque.
    func bedlSilhouetteTemplateMask() -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo)
        else {
            return self
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let luminance = (77 * red + 150 * green + 29 * blue) >> 8
            let sourceAlpha = Int(pixels[offset + 3])
            let silhouetteAlpha: Int
            if sourceAlpha == 0 || luminance >= 235 {
                silhouetteAlpha = 0
            } else if luminance <= 200 {
                silhouetteAlpha = 255
            } else {
                silhouetteAlpha = ((235 - luminance) * 255) / 35
            }
            let alpha = UInt8((silhouetteAlpha * sourceAlpha) / 255)

            pixels[offset] = 255
            pixels[offset + 1] = 255
            pixels[offset + 2] = 255
            pixels[offset + 3] = alpha
        }

        guard let masked = context.makeImage() else {
            return self
        }
        return NSImage(cgImage: masked, size: size)
    }
}

@MainActor
enum BedlIcon {
    static let image: NSImage = {
        let icon = loadImage()
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "밥풀이")
            ?? NSImage()
        icon.isTemplate = false
        return icon
    }()

    private static func loadImage() -> NSImage? {
        for candidate in BedlResourceBundle.candidateURLs {
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(forResource: "bedl-icon", withExtension: "png"),
               let image = NSImage(contentsOf: url)
            {
                return image
            }
        }
        if let url = Bundle.module.url(forResource: "bedl-icon", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

private enum BedlResourceBundle {
    static let bundleName = "token-run_token-run-menubar"

    static var candidateBundles: [Bundle] {
        candidateURLs.compactMap { Bundle(url: $0) }
    }

    static var candidateURLs: [URL] {
        [
            Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
            Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle"),
        ].compactMap { $0 }
    }
}

/// Maps burn state to the per-frame interval for the running Bedlington Terrier.
/// Higher burn → faster animation. `nil` = paused on the standing frame.
extension BurnState {
    /// Per-frame interval for the running Bedlington Terrier. This keeps the
    /// overall gait cycle duration stable as the sprite sheet gains or loses
    /// frames, so 8 frames do not animate slower than the original 5-frame set.
    func bedlFrameInterval(frameCount: Int, speed: Double) -> TimeInterval? {
        guard frameCount > 0, let duration = bedlCycleDuration else { return nil }
        let speed = min(max(speed, 0.5), 2.0)
        return max(0.04, duration / speed / TimeInterval(frameCount))
    }

    private var bedlCycleDuration: TimeInterval? {
        switch self {
        case .idle:   return nil
        case .walk:   return 2.25
        case .jog:    return 1.50
        case .run:    return 1.00
        case .fly:    return 0.65
        case .rocket: return 0.50
        }
    }
}

/// SwiftUI view that animates the bundled Bedlington Terrier sprite in lockstep with
/// `BurnState`. Lives inside the MenuBarExtra label so the menu-bar icon
/// "runs". `height` is driven by `AppSettings.menuBarBedlHeight`.
///
/// Implementation note: `TimelineView` inside `MenuBarExtra`'s label seems to
/// trigger a render-storm in SwiftUI on macOS 14 (100 % CPU + leaking memory
/// every tick), so we drive the frame index with a Combine timer attached
/// only to the `Image` and let SwiftUI diff that single property.
struct RunningBedl: View {
    let state: BurnState
    let height: CGFloat
    let speed: Double

    var body: some View {
        Group {
            let frameCount = BedlFrames.shared.frameCount
            if frameCount > 1, let interval = state.bedlFrameInterval(frameCount: frameCount, speed: speed) {
                FrameCycler(interval: interval, frameCount: frameCount)
            } else {
                BedlFrames.shared.standingImage()
            }
        }
        .onAppear { BedlFrames.shared.setHeight(height) }
        .onChange(of: height) { _, newValue in BedlFrames.shared.setHeight(newValue) }
        .foregroundStyle(.primary)
    }
}

private struct FrameCycler: View {
    let interval: TimeInterval
    let frameCount: Int
    @State private var frameIndex = 0

    var body: some View {
        BedlFrames.shared.image(at: frameIndex)
            .task(id: animationKey) {
                await runAnimationLoop()
            }
    }

    private var animationKey: String {
        "\(frameCount)-\(interval)"
    }

    private func runAnimationLoop() async {
        guard frameCount > 0 else { return }
        await MainActor.run {
            frameIndex %= frameCount
        }

        let nanoseconds = UInt64(max(0.05, interval) * 1_000_000_000)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            await MainActor.run {
                frameIndex = (frameIndex &+ 1) % frameCount
            }
        }
    }
}
