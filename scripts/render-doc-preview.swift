import AppKit
import Foundation
import QuartzCore

// Documentation-only fixtures. This renderer never queries login items or metrics.
enum LoginItemManager {
    struct State {
        let enabled: Bool
        let requiresApproval: Bool
        let title: String
    }
    static func state() -> State { State(enabled: true, requiresApproval: false, title: "Synthetic login preference") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
}

@main
enum RenderDocPreview {
    private static let tabNames = ["cpu", "gpu", "memory", "ssd", "network"]

    private static func populate(_ panel: PanelController) {
        // A deterministic illustrative minute. None of these are live readings.
        let time = Date(timeIntervalSince1970: 1_792_065_600)
        let cpu = [18.0, 19, 25, 22, 28, 34, 31, 26, 23, 32, 40, 33, 27, 24, 29, 35, 39, 31, 25, 22, 27, 31, 28, 26, 33, 29, 25, 24, 30, 28, 28]
        let upload = [0.5, 0.7, 0.4, 0.9, 1.4, 1.0, 0.8, 0.6, 0.5, 1.1, 1.6, 0.8, 0.7, 1.1, 1.3, 1.0, 0.7, 0.9, 1.2, 1.7, 1.3, 0.8, 0.6, 0.9, 1.1, 1.5, 1.0, 0.9, 1.4, 1.1, 1.2]
        let download = [4.5, 6.1, 5.4, 7.8, 8.6, 6.2, 4.9, 6.5, 9.8, 10.5, 8.3, 7.2, 5.9, 6.8, 8.2, 9.7, 10.8, 8.9, 7.0, 6.4, 8.7, 11.2, 9.8, 8.1, 6.6, 7.5, 9.1, 10.2, 8.8, 9.0, 9.4]
        let processes = [
            ResourceProcess(name: "Editor", pid: 101, cpuPercent: 12.4, memoryBytes: 2.1 * 1_024 * 1_024 * 1_024),
            ResourceProcess(name: "Browser", pid: 102, cpuPercent: 8.7, memoryBytes: 1.4 * 1_024 * 1_024 * 1_024),
            ResourceProcess(name: "Terminal", pid: 103, cpuPercent: 3.2, memoryBytes: 384 * 1_024 * 1_024)
        ]
        for index in cpu.indices {
            let seconds = Double(index * 2 - 60)
            let resources = ResourceSnapshot(
                memory: MemorySnapshot(totalBytes: 16 * 1_024 * 1_024 * 1_024, usedBytes: 8 * 1_024 * 1_024 * 1_024,
                    compressedBytes: 512 * 1_024 * 1_024, swapUsedBytes: 0, pressureLevel: 0),
                processes: ProcessSnapshot(cpuTop: processes, memoryTop: processes, cpuReady: true,
                    readableCount: 312, skippedCount: 2, available: true),
                disk: DiskSnapshot(totalBytes: 512_000_000_000, availableBytes: 256_000_000_000,
                    readBytesPerSecond: (14 + download[index]) * 1_000_000,
                    writeBytesPerSecond: (3 + upload[index] * 2.5) * 1_000_000, deviceCount: 1),
                gpu: GPUSnapshot(utilizationPercent: min(100, cpu[index] * 1.5), model: "Apple M4 Pro", coreCount: 20))
            panel.apply(Snapshot(cpuTemperature: 64, ssdTemperature: 42, cpuUsage: cpu[index],
                upload: upload[index] * 1_000_000, download: download[index] * 1_000_000,
                interfaces: 1, cpuSensors: 8, ssdSensors: 2, thermal: ThermalStatus(.nominal),
                time: time.addingTimeInterval(seconds), uptime: 8_280 + seconds, resources: resources, fans: FanSnapshot(rpms: [1800]),
                gpuTemperature: 68, memoryProximityTemperature: 50, gpuSensors: 8, memoryProximitySensors: 2))
        }
    }

    private static func render(tab: Int, language: AppLanguage, appearance: NSAppearance, output: URL) throws -> Data {
        // All persistence is isolated in a disposable domain; no app preferences
        // are written. A new hierarchy per fixture also exercises startup restore.
        let suiteName = "local.mac-thermal.docs.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("Cannot create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(tabNames[tab], forKey: "dashboardSelectedResourceTabV4")
        L10n.setLanguage(language, defaults: defaults)
        // Native glass is composited by WindowServer and omitted by offscreen
        // cacheDisplay. Use the app's real older-macOS artwork for this fixture.
        let panel = PanelController(defaults: defaults, usesNativeAdviceGlass: false)
        let view = panel.view
        view.appearance = appearance
        view.frame = NSRect(origin: .zero, size: PanelController.size)
        populate(panel)
        panel.prepareForPresentation()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()

        // NSGlassEffectView composites through WindowServer and omits offscreen
        // cacheDisplay content. Documentation uses the app's native material
        // fallback around the exact same canvas, cards, fields, and graphs.
        let renderView: NSView
        if #available(macOS 26.0, *),
           let glass = view.subviews.first(where: { $0 is NSGlassEffectView }) as? NSGlassEffectView,
           let canvas = glass.contentView {
            glass.contentView = nil
            canvas.removeFromSuperview()
            let fallback = NSVisualEffectView(frame: NSRect(origin: .zero, size: PanelController.surfaceSize))
            fallback.material = .popover
            fallback.blendingMode = .withinWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = PanelController.cornerRadius
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.masksToBounds = true
            canvas.frame = fallback.bounds
            fallback.addSubview(canvas)
            renderView = fallback
        } else {
            renderView = view
        }
        // This private helper window is never ordered on screen or activated.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: renderView.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        renderView.appearance = appearance
        window.contentView = renderView
        renderView.layoutSubtreeIfNeeded()
        renderView.displayIfNeeded()
        CATransaction.flush()
        let rect = renderView === view
            ? NSRect(x: PanelController.surfaceInset, y: PanelController.surfaceInset,
                width: PanelController.surfaceSize.width, height: PanelController.surfaceSize.height)
            : renderView.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Cannot allocate preview bitmap") }
        bitmap.size = rect.size
        renderView.cacheDisplay(in: rect, to: bitmap)
        // cacheDisplay flattens the layer gradient above selected button text.
        // Draw the actual native selected label last, preserving on-screen order.
        func restoreSelectedTabLabel(_ node: NSView) {
            if let tabs = node as? LiquidTabControl,
               let selected = tabs.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.state == .on }) {
                let destination = selected.convert(selected.bounds, to: renderView)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.cgContext.translateBy(x: destination.minX - rect.minX, y: destination.minY - rect.minY)
                selected.draw(selected.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            node.subviews.forEach(restoreSelectedTabLabel)
        }
        restoreSelectedTabLabel(renderView)
        precondition(bitmap.pixelsWide == Int(PanelController.surfaceSize.width * 2) && bitmap.pixelsHigh == Int(PanelController.surfaceSize.height * 2))
        // Blank renders have repeatedly hidden regressions in offscreen helpers.
        // Verify image data varies before allowing a documentation asset update.
        var distinct = Set<UInt32>()
        if let pixels = bitmap.bitmapData {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                    let offset = y * bitmap.bytesPerRow + x * 4
                    let color = UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2])
                    distinct.insert(color)
                }
            }
        }
        precondition(distinct.count > 64, "Preview unexpectedly blank")
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
        try png.write(to: output, options: .atomic)
        return png
    }

    private static func contactSheet(directory: URL, appearance: String) throws {
        let cellWidth = Int(PanelController.surfaceSize.width), imageHeight = Int(PanelController.surfaceSize.height), cellHeight = Int(PanelController.surfaceSize.height) + 24
        let width = cellWidth * tabNames.count, height = cellHeight * AppLanguage.allCases.count
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot allocate contact sheet") }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: appearance == "light" ? 0.92 : 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (row, language) in AppLanguage.allCases.enumerated() {
            for (column, tab) in tabNames.enumerated() {
                let name = "\(language.rawValue)-\(appearance)-\(tab).png"
                guard let image = NSImage(contentsOf: directory.appendingPathComponent(name)) else {
                    fatalError("Missing generated contact-sheet fixture")
                }
                let x = column * cellWidth, y = height - (row + 1) * cellHeight
                image.draw(in: NSRect(x: x, y: y, width: cellWidth, height: imageHeight))
                let title = "\(language.rawValue) · \(tab) · synthetic"
                (title as NSString).draw(at: NSPoint(x: x + 8, y: y + imageHeight + 4), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: appearance == "light" ? NSColor.black : NSColor.white])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode contact sheet") }
        try png.write(to: directory.appendingPathComponent("contact-sheet-\(appearance).png"), options: .atomic)
    }

    static func main() throws {
        precondition(CommandLine.arguments.count == 3, "Usage: DocPreview canonical-cpu.png fixture-directory")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let canonical = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        for (appearanceName, appearanceValue) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceValue) else { fatalError("Missing system appearance") }
            app.appearance = appearance
            for language in AppLanguage.allCases {
                for tab in tabNames.indices {
                    let name = "\(language.rawValue)-\(appearanceName)-\(tabNames[tab]).png"
                    let png = try render(tab: tab, language: language, appearance: appearance,
                        output: fixtureDirectory.appendingPathComponent(name))
                    if language == .korean && tab == 0 && appearanceName == "light" {
                        try png.write(to: canonical, options: .atomic)
                    }
                }
            }
            try contactSheet(directory: fixtureDirectory, appearance: appearanceName)
        }
        print("Rendered 40 synthetic native resource panels (5 tabs × 4 languages × 2 appearances), 680×840; no live readings or user preferences changed")
        print("Documentation CPU preview: \(canonical.lastPathComponent)")
    }
}
