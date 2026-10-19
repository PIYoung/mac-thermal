import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Documentation-only synthetic values, rendered by the production menu painter.
// The surrounding rounded field is original presentation artwork, not OS chrome.
@main
enum RenderReadmeAssets {
    private static let frameCount = 24
    private static let framesPerSecond = 8.0

    private static var sample: Snapshot {
        Snapshot(cpuTemperature: 64, ssdTemperature: 42, cpuUsage: 28,
            upload: 1_200_000, download: 9_400_000, interfaces: 1,
            cpuSensors: 8, ssdSensors: 2, thermal: ThermalStatus(.nominal),
            time: Date(timeIntervalSince1970: 1_792_065_600), uptime: 8_280,
            resources: ResourceSnapshot(memory: .pending, processes: .pending,
                disk: DiskSnapshot(totalBytes: 512_000_000_000,
                    availableBytes: 256_000_000_000,
                    readBytesPerSecond: 23_400_000, writeBytesPerSecond: 6_000_000,
                    deviceCount: 1), gpu: GPUSnapshot(utilizationPercent: 64, model: "Apple M4 Pro", coreCount: 20)))
    }

    private static func composed(_ image: NSImage) -> CGImage {
        let canvasSize = CGSize(width: max(576, ceil(image.size.width * 2) + 48), height: 92)
        guard let context = CGContext(data: nil, width: Int(canvasSize.width),
            height: Int(canvasSize.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let content = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("Cannot allocate menu artwork")
        }
        let rect = CGRect(origin: .zero, size: canvasSize)
        let field = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
            cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.setFillColor(NSColor(calibratedRed: 0.115, green: 0.13, blue: 0.16, alpha: 1).cgColor)
        context.addPath(field)
        context.fillPath()
        context.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
        context.setLineWidth(1)
        context.addPath(field)
        context.strokePath()
        // Preserve the painter's original 2x pixels; do not enlarge the UI.
        let contentRect = CGRect(x: floor((canvasSize.width - CGFloat(content.width)) / 2),
            y: floor((canvasSize.height - CGFloat(content.height)) / 2),
            width: CGFloat(content.width), height: CGFloat(content.height))
        precondition(contentRect.width <= 748 && contentRect.height == 44,
            "Unexpected production menu painter size")
        context.interpolationQuality = .none
        context.draw(content, in: contentRect)
        guard let result = context.makeImage() else { fatalError("Cannot finish menu artwork") }
        return result
    }

    private static func writePNG(_ image: CGImage, to output: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode static menu artwork")
        }
        try png.write(to: output, options: .atomic)
    }

    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "Usage: RenderReadmeAssets output-directory")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "local.mac-thermal.menu-docs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        L10n.setLanguage(.english, defaults: defaults)
        for (name, metrics) in [("menubar", Set(MenuBarMetric.allCases)), ("menubar-gpu", Set<MenuBarMetric>([.gpu, .ssd, .network]))] {
            let preferences = MenuBarPreferences(style: .rhythm, motionEnabled: true, intensity: 1.2, visibleMetrics: metrics)
            let painter = MenuBarContent.previewRenderer(sample: sample, preferences: preferences, dark: true)
            let output = directory.appendingPathComponent("\(name)-demo.gif")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
                UTType.gif.identifier as CFString, frameCount, nil) else {
                fatalError("Cannot allocate menu GIF encoder")
            }
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
            var renderedFrames = Set<Data>()
            var expectedFrameWidth: Int?
            for index in 0..<frameCount {
                let phase = Double(index) / Double(frameCount)
                guard let image = painter(phase, nil) else { fatalError("Production menu preview failed") }
                let frame = composed(image)
                if let width = expectedFrameWidth { precondition(frame.width == width) }
                else { expectedFrameWidth = frame.width }
                if index == 0 {
                    let snapshot = CodexMonitorSnapshot(appStartedAt: sample.time.addingTimeInterval(-8_280),
                        connection: .connected, recordsEnabled: true, recordsCount: 123,
                        lastRecordAt: sample.time, dailyTokens: 267_000, updatedAt: sample.time)
                    let staticMenu = name == "menubar" ? MenuBarContent.previewCodex(sample: sample,
                        snapshot: snapshot, preferences: preferences, dark: true).0 ?? image : image
                    try writePNG(composed(staticMenu), to: directory.appendingPathComponent("\(name).png"))
                }
                if let data = frame.dataProvider?.data { renderedFrames.insert(data as Data) }
                // GIF stores centiseconds. Alternate 120/130 ms so the complete
                // 24-frame loop remains exactly three seconds (eight fps average).
                let delay = index.isMultiple(of: 2) ? 0.12 : 0.13
                let properties = [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]] as CFDictionary
                CGImageDestinationAddImage(destination, frame, properties)
            }
            precondition(CGImageDestinationFinalize(destination), "Cannot encode menu GIF")
            guard let encoded = CGImageSourceCreateWithURL(output as CFURL, nil) else {
                fatalError("Cannot reopen menu GIF")
            }
            precondition(CGImageSourceGetCount(encoded) == frameCount, "Menu GIF frame count mismatch")
            var encodedFrames = Set<Data>()
            var duration = 0.0
            for index in 0..<frameCount {
                guard let frame = CGImageSourceCreateImageAtIndex(encoded, index, nil) else {
                    fatalError("Cannot decode menu GIF frame")
                }
                precondition(frame.width == expectedFrameWidth && frame.height == 92, "Menu GIF dimensions changed")
                if let data = frame.dataProvider?.data { encodedFrames.insert(data as Data) }
                let metadata = CGImageSourceCopyPropertiesAtIndex(encoded, index, nil) as? [CFString: Any]
                let gif = metadata?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
            }
            precondition(abs(duration - Double(frameCount) / framesPerSecond) < 0.0001,
                "Menu GIF timing changed")
            let bytes = try Data(contentsOf: output).count
            precondition(bytes < 250_000, "Menu GIF exceeds documentation size budget")
            print("Rendered synthetic menu GIF: \(expectedFrameWidth ?? 0)×92, \(frameCount) frames, 8 fps, 3 seconds, \(bytes) bytes")
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                print("System Reduce Motion is enabled; the production painter intentionally remains still")
            } else {
                precondition(renderedFrames.count > 1, "Menu motion unexpectedly static")
                precondition(encodedFrames.count > 1, "Encoded menu GIF unexpectedly static")
                print("Verified \(renderedFrames.count) distinct native frames and \(encodedFrames.count) distinct encoded frames")
            }
        }
    }
}
