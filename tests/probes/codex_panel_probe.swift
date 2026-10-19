import AppKit
import Foundation
import QuartzCore

enum LoginItemManager {
    struct State { let enabled: Bool; let requiresApproval: Bool; let title: String }
    static func state() -> State { State(enabled: false, requiresApproval: false, title: "Fixture") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
}

@main enum CodexPanelProbe {
    private static func canvas(_ panel: CodexPanelController) -> NSView {
        if #available(macOS 26.0, *), let glass = panel.view.subviews.compactMap({ $0 as? NSGlassEffectView }).first,
           let content = glass.contentView { return content }
        return panel.view.subviews.compactMap { $0 as? NSVisualEffectView }.first!.subviews.first!
    }
    private static func bounds(_ node: NSView) {
        for child in node.subviews where !child.isHidden {
            precondition(node.bounds.insetBy(dx: -0.5, dy: -0.5).contains(child.frame),
                "Codex content outside parent: \(type(of: child)) \(child.frame) in \(node.bounds)")
            if !(child is NSControl) { bounds(child) }
        }
    }
    private static func render(_ panel: CodexPanelController, appearance: NSAppearance, output: URL) throws {
        let content = canvas(panel)
        content.removeFromSuperview()
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: CodexPanelController.surfaceSize))
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.appearance = appearance
        content.frame = material.bounds
        material.addSubview(content)
        let window = NSWindow(contentRect: material.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = material
        material.layoutSubtreeIfNeeded()
        material.displayIfNeeded()
        CATransaction.flush()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 840, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = material.bounds.size
        material.cacheDisplay(in: material.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.contentView = nil
        window.close()
    }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "local.mac-thermal.codex-panel-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalLanguage = L10n.language
        defer { L10n.setLanguage(originalLanguage, defaults: defaults) }
        let origin = Date(timeIntervalSince1970: 1_792_065_600)
        let sample = CodexMonitorSnapshot(connection: .connected, activeCount: 2, waitingCount: 1,
            currentModel: "gpt-6.1-sol", currentStartedAt: Date().addingTimeInterval(-125),
            observedActiveSeconds: 3_725, observedTokens: 200, observedSince: origin,
            dailyTokens: 2_500, models: [
                CodexModelUsage(model: "gpt-alpha", totalTokens: 100),
                CodexModelUsage(model: "gpt-beta", totalTokens: 50),
                CodexModelUsage(model: "gpt-delta", totalTokens: 25),
                CodexModelUsage(model: "gpt-gamma", totalTokens: 25)
            ], quotas: [CodexQuota(name: "Codex", usedPercent: 36, windowMinutes: 300, resetsAt: origin),
                CodexQuota(name: "Codex", usedPercent: 72, windowMinutes: 10_080, resetsAt: origin)],
            updatedAt: origin)
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let panel = CodexPanelController()
            _ = panel.view
            let initial = panel.probeStrings
            panel.apply(sample)
            precondition(panel.probeStrings == initial, "Hidden sampling must not format AppKit fields")
            panel.prepareForPresentation()
            panel.view.layoutSubtreeIfNeeded()
            bounds(canvas(panel))
            precondition(panel.preferredContentSize == NSSize(width: 348, height: 468))
            precondition(panel.probeStrings["daily"] == "2.5K")
            precondition(panel.probeStrings["dailyTitle"] == L10n.text("오늘 토큰 (UTC)"))
            let dailyHeading = L10n.text("오늘 토큰 (UTC)") as NSString
            precondition(dailyHeading.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width <= 118,
                "UTC daily heading must fit its fixed width in every language")
            precondition(panel.probeStrings["scope"] == L10n.text("계정 집계"))
            precondition(panel.probeStrings["timeScope"] == L10n.text("이번 연결 관측"))
            precondition(panel.probeStrings["time"] == "1:02:05")
            precondition(panel.probeModelNames == ["gpt-alpha", "gpt-beta", "gpt-delta"])
            precondition(panel.probeModelFractions.compactMap { $0 } == [0.5, 0.25, 0.125])
            precondition(panel.probeQuotaValues == ["36% / 64%", "72% / 28%"])
            precondition(!panel.probeCardsAreDimmed)
            var refreshes = 0
            panel.refresh = { refreshes += 1 }
            panel.probeRefresh()
            precondition(refreshes == 1, "Refresh must invoke only the supplied callback")
            panel.probeSetVisible(true)
            var unavailable = sample
            unavailable.connection = .unavailable
            unavailable.currentStartedAt = origin
            unavailable.updatedAt = origin.addingTimeInterval(125)
            panel.apply(unavailable)
            precondition(panel.probeStrings["elapsed"] == "02:05", "Disconnected elapsed time must freeze at the last update")
            precondition(panel.probeStrings["updated"]?.hasPrefix(L10n.format("이전 값 · %@", "")) == true)
            precondition(panel.probeCardsAreDimmed)
            panel.apply(unavailable)
            precondition(panel.probeStrings["elapsed"] == "02:05")
            var unknown = CodexMonitorSnapshot.pending
            unknown.connection = .connected
            unknown.observedTokens = 5_000
            unknown.models = sample.models
            unknown.currentModel = "/Users/private/workspace"
            unknown.noticeKey = "Private raw server error"
            unknown.quotas = [CodexQuota(name: "/Users/private/path", usedPercent: .nan, windowMinutes: nil, resetsAt: nil),
                CodexQuota(name: "Second", usedPercent: 150, windowMinutes: 300, resetsAt: nil),
                CodexQuota(name: "Hidden", usedPercent: 25, windowMinutes: 1_440, resetsAt: origin)]
            panel.apply(unknown)
            precondition(panel.probeStrings["daily"] == L10n.text("정보 없음"), "Observed tokens must never replace account daily tokens")
            precondition(panel.probeStrings["model"] == L10n.text("정보 없음"))
            precondition(panel.probeQuotaValues == [L10n.text("정보 없음"), L10n.text("정보 없음")])
            precondition(panel.probeQuotaFractions.allSatisfy { $0 == nil })
            precondition(!panel.probeStrings.values.contains(where: { $0.contains("Private raw") || $0.contains("/Users/private") }))
            panel.apply(.pending)
            precondition(panel.probeModelNames.isEmpty && panel.probeQuotaValues.isEmpty)
            precondition(panel.probeStrings["daily"] == L10n.text("정보 없음") && panel.probeStrings["time"] == L10n.text("정보 없음"))
            var runtime = CodexMonitorSnapshot.pending
            runtime.connection = .unavailable
            runtime.appStartedAt = Date().addingTimeInterval(-120)
            panel.apply(runtime)
            precondition(panel.probeStrings["elapsed"]?.hasPrefix(L10n.format("앱 %@", "")) == true)
            precondition(panel.probeStrings["elapsedNotice"] == L10n.text("Codex 앱 실행 후 경과 시간입니다. 작업 활동 시간과 다릅니다."))
            precondition(panel.probeStrings["time"] == L10n.text("정보 없음"), "App runtime must never become observed task time")
            for invalidStart in [nil, Date(timeIntervalSince1970: .nan), Date().addingTimeInterval(60)] as [Date?] {
                runtime.appStartedAt = invalidStart
                panel.apply(runtime)
                precondition(panel.probeStrings["elapsed"] == "—", "Invalid or unavailable launch dates must not become fake runtime")
            }
            runtime.appStartedAt = Date().addingTimeInterval(-120)
            runtime.connection = .notRunning
            panel.apply(runtime)
            precondition(panel.probeStrings["elapsed"] == "—", "A stopped app must not show a continuing runtime")
            bounds(canvas(panel))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            L10n.setLanguage(.korean, defaults: defaults)
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let appearance = NSAppearance(named: appearanceName)!
                app.appearance = appearance
                let panel = CodexPanelController()
                panel.apply(sample)
                panel.prepareForPresentation()
                try render(panel, appearance: appearance, output: output.appendingPathComponent("codex-connected-\(name).png"))
                let missing = CodexPanelController()
                var unavailable = CodexMonitorSnapshot.pending
                unavailable.connection = .unavailable
                unavailable.noticeKey = "공유 Codex 서버에 연결할 수 없습니다"
                missing.apply(unavailable)
                missing.prepareForPresentation()
                try render(missing, appearance: appearance, output: output.appendingPathComponent("codex-unavailable-\(name).png"))
            }
        }
        print("Codex panel passed: 4-language fixed bounds, hidden updates, refresh callback, account/observed separation, real quota limits, frozen stale time, safe metadata and unknown states; no server or private file access")
    }
}
