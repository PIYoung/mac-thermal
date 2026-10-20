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
        let sample = CodexMonitorSnapshot(appStartedAt: Date().addingTimeInterval(-125),
            connection: .connected, recordsEnabled: true, recordsCount: 123, lastRecordAt: origin,
            currentModel: "gpt-6.1-sol", dailyTokens: 2_500, models: [
                CodexModelUsage(model: "gpt-alpha", totalTokens: 100),
                CodexModelUsage(model: "gpt-beta", totalTokens: 50),
                CodexModelUsage(model: "gpt-delta", totalTokens: 25),
                CodexModelUsage(model: "gpt-gamma", totalTokens: 25)
            ], updatedAt: origin)
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let panel = CodexPanelController()
            _ = panel.view
            let initial = panel.probeStrings
            panel.apply(sample)
            precondition(panel.probeStrings == initial,
                "Hidden sampling must not format AppKit fields")
            panel.prepareForPresentation()
            panel.view.layoutSubtreeIfNeeded()
            precondition(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            precondition(panel.preferredContentSize == NSSize(width: 348, height: 468))
            precondition(panel.probeSeparateCardsVisible, "Graph and model cards must stay visible together without overlap")
            precondition(panel.probeChartFrame.height == 67, "Graph must fit above the separate models card")
            func visibleText(_ node: NSView) -> [String] {
                node.subviews.flatMap { child -> [String] in
                    guard !child.isHidden else { return [] }
                    return (child as? NSTextField).map { [$0.stringValue] } ?? visibleText(child)
                }
            }
            precondition(!visibleText(canvas(panel)).contains(L10n.text("최근 기록")))
            func hasToggle(_ node: NSView) -> Bool {
                node.subviews.contains { child in
                    if let button = child as? NSButton,
                       [L10n.text("모델 보기"), L10n.text("그래프")].contains(button.title) { return true }
                    return hasToggle(child)
                }
            }
            precondition(!hasToggle(canvas(panel)), "No graph/model toggle should remain")
            precondition(!visibleText(canvas(panel)).contains(L10n.text("로컬 기록 읽기")))
            precondition(panel.probeStrings["daily"] == "2.5K")
            precondition(panel.probeStrings["dailyTitle"] == L10n.text("오늘 토큰 (UTC)"))
            let dailyHeading = L10n.text("오늘 토큰 (UTC)") as NSString
            precondition(dailyHeading.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width <= 126,
                "UTC daily heading must fit its fixed width in every language")
            let modelHeading = L10n.text("모델별 · 오늘 TOP 3") as NSString
            precondition(modelHeading.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width <= 174)
            precondition(panel.probeStrings["scope"] == L10n.text("이 Mac 기록"))
            let partialScope = L10n.text("이 Mac 기록 · 일부") as NSString
            precondition(partialScope.size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)]).width <= 126,
                "The local-source scope must fit beside the today heading")
            precondition(panel.probeStrings["counts"] == L10n.format("오늘 %lld개 기록", Int64(123)))
            precondition(panel.probeStrings["elapsed"]?.hasPrefix(L10n.format("앱 %@", "")) == true)
            precondition(panel.probeModelNames == ["gpt-alpha", "gpt-beta", "gpt-delta"])
            precondition(panel.probeModelFractions.compactMap { $0 } == [0.5, 0.25, 0.125])
            precondition(!panel.probeCardsAreDimmed)
            var refreshes = 0
            panel.refresh = { refreshes += 1 }
            panel.probeRefresh()
            precondition(refreshes == 1, "Refresh must invoke only the supplied callback")
            panel.probeSetVisible(true)
            var disabled = CodexMonitorSnapshot.pending
            panel.apply(disabled)
            precondition(panel.probeModelNames.isEmpty && panel.probeStrings["daily"] == L10n.text("정보 없음"))
            panel.probeRefresh()
            precondition(refreshes == 1, "Off must not trigger a refresh read")
            disabled.recordsEnabled = true
            disabled.connection = .connecting
            panel.apply(disabled)
            precondition(panel.probeStrings["activity"] == L10n.text("로컬 기록 확인 중"))
            precondition(panel.probeStrings["daily"] == L10n.text("정보 없음"), "Re-enable must wait for a new scan")
            var unavailable = sample
            unavailable.connection = .unavailable
            panel.apply(unavailable)
            precondition(panel.probeStrings["updated"]?.hasPrefix(L10n.format("이전 값 · %@", "")) == true)
            precondition(panel.probeCardsAreDimmed)
            var partial = sample
            partial.incomplete = true
            partial.dailyTokens = 0
            panel.apply(partial)
            precondition(panel.probeStrings["scope"] == L10n.text("이 Mac 기록 · 일부"))
            precondition(panel.probeStrings["daily"] == L10n.text("정보 없음"), "A partial scan must not claim a complete zero")
            var unknown = CodexMonitorSnapshot.pending
            unknown.connection = .connected
            unknown.recordsEnabled = true
            unknown.currentModel = "/Users/private/workspace"
            unknown.models = [CodexModelUsage(model: "/Users/private/model", totalTokens: 100)]
            unknown.noticeKey = "Private raw server error"
            unknown.lastRecordAt = Date(timeIntervalSince1970: .nan)
            unknown.recordsCount = -1
            panel.apply(unknown)
            precondition(panel.probeStrings["daily"] == L10n.text("정보 없음"))
            precondition(panel.probeStrings["model"] == L10n.text("정보 없음"))
            precondition(panel.probeStrings["counts"] == "—")
            precondition(panel.probeModelNames.isEmpty)
            precondition(!panel.probeStrings.values.contains(where: { $0.contains("Private raw") || $0.contains("/Users/private") }))
            var off = sample
            off.recordsEnabled = false
            panel.apply(off)
            precondition(panel.probeModelNames.isEmpty)
            precondition(panel.probeStrings["daily"] == L10n.text("정보 없음"))
            var runtime = CodexMonitorSnapshot.pending
            runtime.connection = .unavailable
            runtime.appStartedAt = Date().addingTimeInterval(-120)
            panel.apply(runtime)
            precondition(panel.probeStrings["elapsed"]?.hasPrefix(L10n.format("앱 %@", "")) == true)
            precondition(panel.probeStrings["elapsedNotice"] == L10n.text("Codex 앱 실행 후 경과 시간입니다. 작업 활동 시간과 다릅니다."))
            for invalidStart in [nil, Date(timeIntervalSince1970: .nan), Date().addingTimeInterval(60)] as [Date?] {
                runtime.appStartedAt = invalidStart
                panel.apply(runtime)
                precondition(panel.probeStrings["elapsed"] == "—", "Invalid or unavailable launch dates must not become fake runtime")
            }
            runtime.appStartedAt = Date().addingTimeInterval(-120)
            runtime.connection = .notRunning
            panel.apply(runtime)
            precondition(panel.probeStrings["elapsed"] == "—", "A stopped app must not show a continuing runtime")
            var graph = sample
            let usageNow = Date()
            let template = CodexUsageSnapshot.parse(["dailyUsageBuckets": []], now: usageNow)
            graph.quota.usage = CodexUsageSnapshot(state: .ready, days: template.days.enumerated().map {
                CodexDailyUsage(day: $0.element.day, tokens: $0.offset == 3 ? nil : Int64([0, 4000, 1200, 0, 6000, 2800, 4200][$0.offset]))
            }, fetchedAt: usageNow)
            panel.apply(graph)
            precondition(panel.probeUsageReady && panel.probeUsageTitle == L10n.text("최근 7일"))
            precondition(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            graph.quota.usage.fetchedAt = usageNow.addingTimeInterval(-901)
            panel.apply(graph)
            precondition(!panel.probeUsageReady && panel.probeUsageStatus == L10n.text("사용량 통계 갱신 대기 중"))
            precondition(panel.probeSeparateCardsVisible, "Unavailable graph data must not hide the local models")
            var account = sample
            let fresh = Date()
            account.quota = CodexQuotaSnapshot(connection: .connected, windows: [
                CodexQuotaWindow(slot: 0, usedPercent: 32, durationMinutes: 300, resetsAt: fresh.addingTimeInterval(7200)),
                CodexQuotaWindow(slot: 1, usedPercent: 75, durationMinutes: 10080, resetsAt: fresh.addingTimeInterval(4 * 86400))
            ], fetchedAt: fresh)
            panel.apply(account)
            precondition(panel.probeQuotaIsVisible && panel.probeQuotaStrings.prefix(2) == ["5h", "7d"])
            precondition(panel.probeQuotaStrings[2] == L10n.format("잔여 %.0f%%", 68.0))
            precondition(panel.probeQuotaStrings[4].hasPrefix(L10n.format("리셋 %@", "")))
            account.recordsEnabled = false
            panel.apply(account); panel.probeRefresh()
            precondition(refreshes == 2 && panel.probeQuotaIsVisible, "Quota refresh is independent of local records")
            precondition(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            account.quota.windows[0] = CodexQuotaWindow(slot: 0, usedPercent: 32, durationMinutes: 300, resetsAt: fresh.addingTimeInterval(-1))
            panel.apply(account)
            precondition(panel.probeQuotaStrings[2] == "—" && panel.probeQuotaStrings[4] == L10n.text("리셋 확인 중"))
            account.quota.fetchedAt = fresh.addingTimeInterval(-181)
            panel.apply(account)
            precondition(panel.probeQuotaStatus == L10n.text("한도 갱신 대기 중"))
            account.quota.fetchedAt = fresh
            account.quota.windows = [account.quota.windows[1]]
            panel.apply(account)
            precondition(panel.probeQuotaVisibleRows == 1 && panel.probeQuotaStrings[0] == "7d", "A sole secondary window must occupy the first visible row")
            precondition(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            account.quota = CodexQuotaSnapshot()
            panel.apply(account)
            precondition(!panel.probeQuotaIsVisible)
            precondition(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var documentation = sample
            documentation.appStartedAt = Date().addingTimeInterval(-8_280)
            documentation.currentModel = "model-alpha"
            documentation.dailyTokens = 267_000
            documentation.quota = CodexQuotaSnapshot(connection: .connected, windows: [
                CodexQuotaWindow(slot: 0, usedPercent: 32, durationMinutes: 300, resetsAt: Date().addingTimeInterval(7200)),
                CodexQuotaWindow(slot: 1, usedPercent: 75, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(4 * 86400))
            ], fetchedAt: Date())
            let usageNow = Date()
            let template = CodexUsageSnapshot.parse(["dailyUsageBuckets": []], now: usageNow)
            documentation.quota.usage = CodexUsageSnapshot(state: .ready, days: template.days.enumerated().map {
                CodexDailyUsage(day: $0.element.day, tokens: Int64([18000, 64000, 32000, 91000, 47000, 76000, 56000][$0.offset]))
            }, fetchedAt: usageNow)
            documentation.models = [CodexModelUsage(model: "model-alpha", totalTokens: 182_000),
                                    CodexModelUsage(model: "model-beta", totalTokens: 64_000),
                                    CodexModelUsage(model: "model-gamma", totalTokens: 21_000)]
            for language in AppLanguage.allCases {
                L10n.setLanguage(language, defaults: defaults)
                let appearance = NSAppearance(named: .aqua)!
                app.appearance = appearance
                let panel = CodexPanelController()
                panel.apply(documentation)
                panel.prepareForPresentation()
                try render(panel, appearance: appearance, output: output.appendingPathComponent("codex-\(language.rawValue)-light.png"))
            }
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
                unavailable.recordsEnabled = true
                unavailable.appStartedAt = Date().addingTimeInterval(-2_533)
                unavailable.noticeKey = "로컬 Codex 기록을 읽을 수 없습니다"
                missing.apply(unavailable)
                missing.prepareForPresentation()
                try render(missing, appearance: appearance, output: output.appendingPathComponent("codex-unavailable-\(name).png"))
            }
        }
        print("Codex panel passed: 4-language fixed bounds, simultaneous separate graph/models cards without toggle, removed recent-record and settings items, local UTC-today scope, hidden updates, stale/partial/unknown states, app runtime and safe metadata; synthetic only, no local-record or server access")
    }
}
