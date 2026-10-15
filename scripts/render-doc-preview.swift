import AppKit
import Foundation
import QuartzCore

// Documentation-only fixture. This renderer never queries login items or metrics.
enum LoginItemManager {
    struct State {
        let enabled: Bool
        let requiresApproval: Bool
        let title: String
    }
    static func state() -> State { State(enabled: true, requiresApproval: false, title: "Sample login preference") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
}

@main
enum RenderDocPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)

        // These overrides live in this helper process only; no real preferences
        // are changed. Language persistence is directed to a disposable suite.
        UserDefaults.standard.setVolatileDomain([
            "dashboardSelectedTabV2": 0,
            AppLanguage.defaultsKey: AppLanguage.korean.rawValue,
            "menuBarAnimationStyleV2": 0,
            "menuBarMotionEnabledV2": true,
            "menuBarMotionIntensityV2": 1.2
        ], forName: UserDefaults.argumentDomain)
        let suiteName = "local.mac-thermal.docs.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("Cannot create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        L10n.setLanguage(.korean, defaults: defaults)

        let panel = PanelController()
        let view = panel.view
        view.appearance = app.appearance
        view.frame = NSRect(origin: .zero, size: PanelController.size)

        // A deterministic minute of illustrative values, ending at the numbers
        // shown below. No sensor functions or process enumeration are linked.
        let time = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15 12:00 UTC
        let cpu = [18.0, 19, 25, 22, 28, 34, 31, 26, 23, 32, 40, 33, 27, 24, 29, 35, 39, 31, 25, 22, 27, 31, 28, 26, 33, 29, 25, 24, 30, 28, 28]
        let upload = [0.5, 0.7, 0.4, 0.9, 1.4, 1.0, 0.8, 0.6, 0.5, 1.1, 1.6, 0.8, 0.7, 1.1, 1.3, 1.0, 0.7, 0.9, 1.2, 1.7, 1.3, 0.8, 0.6, 0.9, 1.1, 1.5, 1.0, 0.9, 1.4, 1.1, 1.2]
        let download = [4.5, 6.1, 5.4, 7.8, 8.6, 6.2, 4.9, 6.5, 9.8, 10.5, 8.3, 7.2, 5.9, 6.8, 8.2, 9.7, 10.8, 8.9, 7.0, 6.4, 8.7, 11.2, 9.8, 8.1, 6.6, 7.5, 9.1, 10.2, 8.8, 9.0, 9.4]
        let resources = ResourceSnapshot(
            memory: MemorySnapshot(totalBytes: 16 * 1_024 * 1_024 * 1_024, usedBytes: 8 * 1_024 * 1_024 * 1_024,
                compressedBytes: 512 * 1_024 * 1_024, swapUsedBytes: 0, pressureLevel: 0),
            processes: .pending,
            disk: DiskSnapshot(totalBytes: 512_000_000_000, availableBytes: 256_000_000_000,
                readBytesPerSecond: 24_000_000, writeBytesPerSecond: 6_000_000, deviceCount: 1))
        for index in cpu.indices {
            let seconds = Double(index * 2 - 60)
            panel.apply(Snapshot(cpuTemperature: 64, ssdTemperature: 42, cpuUsage: cpu[index],
                upload: upload[index] * 1_000_000, download: download[index] * 1_000_000,
                interfaces: 1, cpuSensors: 8, ssdSensors: 2, thermal: ThermalStatus(.nominal),
                time: time.addingTimeInterval(seconds), uptime: 8_280 + seconds, resources: resources))
        }
        panel.prepareForPresentation()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()

        // NSGlassEffectView composites through WindowServer and does not include
        // its content in cacheDisplay offscreen. For documentation only, place
        // the same native canvas in the app's standard material fallback.
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
        window.appearance = app.appearance
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
        // cacheDisplay flattens a layer-backed control's gradient above the
        // selected button drawing. Draw that actual native button last to
        // preserve the on-screen label's layer ordering in the PNG.
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
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try png.write(to: output, options: .atomic)
        print("Rendered synthetic native panel: \(output.lastPathComponent), \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
    }
}
