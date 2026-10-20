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
        node.layoutSubtreeIfNeeded()
        if let scroll = node as? NSScrollView, let document = scroll.documentView {
            verify(document.frame.width <= scroll.contentSize.width + 0.5)
            bounds(document); return
        }
        for child in node.subviews where !child.isHidden {
            verify(node.bounds.insetBy(dx: -0.5, dy: -0.5).contains(child.frame),
                "Codex content outside parent: \(type(of: child)) \(child.frame) in \(node.bounds)")
            if !(child is NSControl) { bounds(child) }
        }
    }
    private static func render(_ panel: CodexPanelController, appearance: NSAppearance, output: URL, scrollY: CGFloat = 0) throws {
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
        panel.probeScrollInsights(scrollY)
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
    private static func verify(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        guard condition() else {
            fputs("Codex panel failed at \(file):\(line): \(message)\n", stderr)
            exit(1)
        }
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
            verify(panel.probeStrings == initial,
                "Hidden sampling must not format AppKit fields")
            panel.prepareForPresentation()
            panel.view.layoutSubtreeIfNeeded()
            verify(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            verify(panel.preferredContentSize == NSSize(width: 348, height: 468))
            verify(panel.probeSeparateCardsVisible, "Token composition and model cards must stay visible together without overlap")
            func visibleText(_ node: NSView) -> [String] {
                node.subviews.flatMap { child -> [String] in
                    guard !child.isHidden else { return [] }
                    return (child as? NSTextField).map { [$0.stringValue] } ?? visibleText(child)
                }
            }
            verify(!visibleText(canvas(panel)).contains(L10n.text("최근 기록")))
            verify(!visibleText(canvas(panel)).contains(L10n.text("최근 7일")))
            verify(!visibleText(canvas(panel)).contains(L10n.text("최근 10분 · 이 Mac 기록")))
            func hasToggle(_ node: NSView) -> Bool {
                node.subviews.contains { child in
                    if let button = child as? NSButton,
                       [L10n.text("모델 보기"), L10n.text("그래프")].contains(button.title) { return true }
                    return hasToggle(child)
                }
            }
            verify(!hasToggle(canvas(panel)), "No graph/model toggle should remain")
            verify(!visibleText(canvas(panel)).contains(L10n.text("로컬 기록 읽기")))
            verify(panel.probeStrings["daily"] == "2.5K")
            verify(panel.probeStrings["dailyTitle"] == L10n.text("오늘 토큰 (UTC)"))
            let dailyHeading = L10n.text("오늘 토큰 (UTC)") as NSString
            verify(dailyHeading.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width <= 126,
                "UTC daily heading must fit its fixed width in every language")
            let modelHeading = L10n.text("모델별 · 오늘 TOP 3") as NSString
            verify(modelHeading.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width <= 174)
            verify(panel.probeStrings["scope"] == L10n.text("이 Mac 기록"))
            let partialScope = L10n.text("이 Mac 기록 · 일부") as NSString
            verify(partialScope.size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)]).width <= 114,
                "The local-source scope must fit beside the today heading")
            verify(panel.probeStrings["counts"] == L10n.format("오늘 %lld개 기록", Int64(123)))
            verify(panel.probeStrings["elapsed"]?.hasPrefix(L10n.format("앱 %@", "")) == true)
            verify(panel.probeModelNames == ["gpt-alpha", "gpt-beta", "gpt-delta"])
            verify(panel.probeModelFractions.compactMap { $0 } == [0.5, 0.25, 0.125])
            verify(!panel.probeCardsAreDimmed)
            var refreshes = 0
            panel.refresh = { refreshes += 1 }
            panel.probeRefresh()
            verify(refreshes == 1, "Refresh must invoke only the supplied callback")
            panel.probeSetVisible(true)
            var disabled = CodexMonitorSnapshot.pending
            panel.apply(disabled)
            verify(panel.probeModelNames.isEmpty && panel.probeStrings["daily"] == L10n.text("정보 없음"))
            panel.probeRefresh()
            verify(refreshes == 1, "Off must not trigger a refresh read")
            disabled.recordsEnabled = true
            disabled.connection = .connecting
            panel.apply(disabled)
            verify(panel.probeStrings["activity"] == L10n.text("로컬 기록 확인 중"))
            verify(panel.probeStrings["daily"] == L10n.text("정보 없음"), "Re-enable must wait for a new scan")
            var unavailable = sample
            unavailable.connection = .unavailable
            panel.apply(unavailable)
            verify(panel.probeStrings["updated"]?.hasPrefix(L10n.format("이전 값 · %@", "")) == true)
            verify(panel.probeCardsAreDimmed)
            var partial = sample
            partial.incomplete = true
            partial.dailyTokens = 0
            panel.apply(partial)
            verify(panel.probeStrings["scope"] == L10n.text("이 Mac 기록 · 일부"))
            verify(panel.probeStrings["daily"] == L10n.text("정보 없음"), "A partial scan must not claim a complete zero")
            var unknown = CodexMonitorSnapshot.pending
            unknown.connection = .connected
            unknown.recordsEnabled = true
            unknown.currentModel = "/Users/private/workspace"
            unknown.models = [CodexModelUsage(model: "/Users/private/model", totalTokens: 100)]
            unknown.noticeKey = "Private raw server error"
            unknown.lastRecordAt = Date(timeIntervalSince1970: .nan)
            unknown.recordsCount = -1
            panel.apply(unknown)
            verify(panel.probeStrings["daily"] == L10n.text("정보 없음"))
            verify(panel.probeStrings["model"] == L10n.text("정보 없음"))
            verify(panel.probeStrings["counts"] == "—")
            verify(panel.probeModelNames.isEmpty)
            verify(!panel.probeStrings.values.contains(where: { $0.contains("Private raw") || $0.contains("/Users/private") }))
            var off = sample
            off.recordsEnabled = false
            panel.apply(off)
            verify(panel.probeModelNames.isEmpty)
            verify(panel.probeStrings["daily"] == L10n.text("정보 없음"))
            var runtime = CodexMonitorSnapshot.pending
            runtime.connection = .unavailable
            runtime.appStartedAt = Date().addingTimeInterval(-120)
            panel.apply(runtime)
            verify(panel.probeStrings["elapsed"]?.hasPrefix(L10n.format("앱 %@", "")) == true)
            verify(panel.probeStrings["elapsedNotice"] == L10n.text("Codex 앱 실행 후 경과 시간입니다. 작업 활동 시간과 다릅니다."))
            for invalidStart in [nil, Date(timeIntervalSince1970: .nan), Date().addingTimeInterval(60)] as [Date?] {
                runtime.appStartedAt = invalidStart
                panel.apply(runtime)
                verify(panel.probeStrings["elapsed"] == "—", "Invalid or unavailable launch dates must not become fake runtime")
            }
            runtime.appStartedAt = Date().addingTimeInterval(-120)
            runtime.connection = .notRunning
            panel.apply(runtime)
            verify(panel.probeStrings["elapsed"] == "—", "A stopped app must not show a continuing runtime")
            var accountPrompts = 0, statsPrompts = 0
            panel.accountAction = { accountPrompts += 1 }
            panel.usageAction = { statsPrompts += 1 }
            for state: CodexQuotaConnection in [.disconnected, .needsLogin] {
                var loggedOut = sample
                loggedOut.quota.connection = state
                // Even an unexpected cached payload must never render after sign-out.
                let now = Date()
                loggedOut.quota.usage = CodexUsageSnapshot(state: .ready, days: [CodexDailyUsage(day: "2026-10-20", tokens: 999)], fetchedAt: now)
                panel.apply(loggedOut)
                verify(panel.probeUsageStatus == L10n.text("로그인 후 계정 토큰을 볼 수 있습니다"))
                verify(!panel.probeUsageReady && panel.probeUsageButtonVisible)
                verify(panel.probeUsageButtonTitle == L10n.text("ChatGPT 로그인"))
                verify(panel.probeModelNames.count == 3, "Local models must remain independent of account sign-in")
                panel.probeClickUsageAction()
            }
            verify(accountPrompts == 2 && statsPrompts == 0, "Logged-out graph action must open sign-in review, never enable queries")
            var consent = sample
            consent.quota.connection = .connected
            panel.apply(consent)
            verify(panel.probeUsageStatus == L10n.text("동의 후 계정 통계를 표시합니다"))
            panel.probeClickUsageAction()
            verify(statsPrompts == 1 && accountPrompts == 2, "Connected users must still explicitly review daily-statistics opt-in")
            for state: CodexQuotaConnection in [.connecting, .authorizing, .disconnecting] {
                consent.quota.connection = state; panel.apply(consent)
                verify(!panel.probeUsageReady && !panel.probeUsageButtonVisible)
            }
            for state: CodexQuotaConnection in [.helperMissing, .unavailable] {
                consent.quota.connection = state; panel.apply(consent)
                verify(!panel.probeUsageReady && panel.probeUsageButtonVisible)
                verify(panel.probeUsageButtonTitle == L10n.text("ChatGPT 한도 관리"))
            }
            var graph = sample
            let usageNow = Date()
            let template = CodexUsageSnapshot.parse(["dailyUsageBuckets": []], now: usageNow)
            graph.quota.connection = .connected
            graph.quota.usage = CodexUsageSnapshot(state: .ready, days: template.days.enumerated().map {
                CodexDailyUsage(day: $0.element.day, tokens: $0.offset == 3 ? nil : Int64([0, 4000, 1200, 0, 6000, 2800, 4200][$0.offset]))
            }, fetchedAt: usageNow)
            graph.models = [CodexModelUsage(model: "gpt-alpha", inputTokens: 1000, cachedInputTokens: 750, outputTokens: 500, reasoningOutputTokens: 250, totalTokens: 1500)]
            graph.dailyTokens = 1500
            graph.quota.usage.summaryEnabled = true
            graph.quota.usage.summary = CodexAccountSummary(lifetimeTokens: 100000, peakDailyTokens: 50000, longestRunningTurnSec: 540, currentStreakDays: 8, longestStreakDays: 14)
            panel.apply(graph)
            verify(panel.probeBreakdown == ["1.0K", "500", L10n.format("%.0f%%", 75.0), L10n.format("%.0f%%", 50.0)])
            verify(panel.probeWeek[3] == "6/7", "Missing day must be excluded from account averages")
            verify(panel.probeSummary.count == 5 && panel.probeSummary[4] == "09:00")
            var noDates = graph
            noDates.quota.usage.days = []
            panel.apply(noDates)
            let beforeManage = statsPrompts
            panel.probeClickUsageAction()
            verify(statsPrompts == beforeManage + 1 && panel.probeSummary.count == 5, "Statistics management remains accessible when daily buckets are absent but account summary is available")
            panel.apply(graph)
            let collapsed = panel.probeInsightsHeight
            panel.probeExpandModel(0)
            verify(panel.probeModelDetails == panel.probeBreakdown && panel.probeInsightsHeight > collapsed)
            bounds(canvas(panel))
            panel.probeExpandModel(0)
            verify(panel.probeModelDetails.isEmpty && panel.probeInsightsHeight == collapsed)
            verify(panel.probeUsageReady)
            verify(!visibleText(canvas(panel)).contains(L10n.text("최근 7일")))
            verify(!visibleText(canvas(panel)).contains(L10n.text("최근 10분 · 이 Mac 기록")))
            verify(collapsed < 500 && panel.probeLocalCardsFit, "Today, composition and models must fit before scrolling; account summaries stay below")
            verify(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            graph.quota.usage.fetchedAt = usageNow.addingTimeInterval(-901)
            panel.apply(graph)
            verify(!panel.probeUsageReady && panel.probeUsageStatus == L10n.text("사용량 통계 갱신 대기 중"))
            verify(panel.probeSeparateCardsVisible, "Unavailable graph data must not hide the local models")
            var account = sample
            let fresh = Date()
            account.quota = CodexQuotaSnapshot(connection: .connected, windows: [
                CodexQuotaWindow(slot: 0, usedPercent: 32, durationMinutes: 300, resetsAt: fresh.addingTimeInterval(7200)),
                CodexQuotaWindow(slot: 1, usedPercent: 75, durationMinutes: 10080, resetsAt: fresh.addingTimeInterval(4 * 86400))
            ], fetchedAt: fresh)
            panel.apply(account)
            verify(panel.probeQuotaIsVisible && panel.probeQuotaStrings.prefix(2) == ["5h", "7d"])
            verify(panel.probeQuotaStrings[2] == L10n.format("잔여 %.0f%%", 68.0))
            verify(panel.probeQuotaStrings[4].hasPrefix(L10n.format("리셋 %@", "")))
            account.recordsEnabled = false
            panel.apply(account); panel.probeRefresh()
            verify(refreshes == 2 && panel.probeQuotaIsVisible, "Quota refresh is independent of local records")
            verify(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            account.quota.windows[0] = CodexQuotaWindow(slot: 0, usedPercent: 32, durationMinutes: 300, resetsAt: fresh.addingTimeInterval(-1))
            panel.apply(account)
            verify(panel.probeQuotaStrings[2] == "—" && panel.probeQuotaStrings[4] == L10n.text("리셋 확인 중"))
            account.quota.fetchedAt = fresh.addingTimeInterval(-181)
            panel.apply(account)
            verify(panel.probeQuotaStatus == L10n.text("한도 갱신 대기 중"))
            account.quota.fetchedAt = fresh
            account.quota.windows = [account.quota.windows[1]]
            panel.apply(account)
            verify(panel.probeQuotaVisibleRows == 1 && panel.probeQuotaStrings[0] == "7d", "A sole secondary window must occupy the first visible row")
            verify(panel.probeSeparateCardsVisible)
            bounds(canvas(panel))
            account.quota = CodexQuotaSnapshot()
            panel.apply(account)
            verify(!panel.probeQuotaIsVisible)
            verify(panel.probeSeparateCardsVisible)
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
            documentation.models = [CodexModelUsage(model: "model-alpha", inputTokens: 150_000, cachedInputTokens: 120_000, outputTokens: 32_000, reasoningOutputTokens: 12_000, totalTokens: 182_000),
                                    CodexModelUsage(model: "model-beta", inputTokens: 50_000, cachedInputTokens: 20_000, outputTokens: 14_000, reasoningOutputTokens: 4_000, totalTokens: 64_000),
                                    CodexModelUsage(model: "model-gamma", inputTokens: 17_000, cachedInputTokens: 9_000, outputTokens: 4_000, reasoningOutputTokens: 2_000, totalTokens: 21_000)]
            documentation.quota.usage.summaryEnabled = true
            documentation.quota.usage.summary = CodexAccountSummary(lifetimeTokens: 1234567890, peakDailyTokens: 9123456, longestRunningTurnSec: 540, currentStreakDays: 8, longestStreakDays: 14)
            for language in AppLanguage.allCases {
                L10n.setLanguage(language, defaults: defaults)
                let appearance = NSAppearance(named: .aqua)!
                app.appearance = appearance
                let panel = CodexPanelController()
                panel.apply(documentation)
                panel.prepareForPresentation()
                try render(panel, appearance: appearance, output: output.appendingPathComponent("codex-\(language.rawValue)-light.png"))
                let detailPanel = CodexPanelController()
                detailPanel.apply(documentation); detailPanel.prepareForPresentation(); detailPanel.probeExpandModel(0)
                try render(detailPanel, appearance: appearance, output: output.appendingPathComponent("codex-insights-\(language.rawValue).png"), scrollY: 150)
                let summaryPanel = CodexPanelController()
                summaryPanel.apply(documentation); summaryPanel.prepareForPresentation()
                try render(summaryPanel, appearance: appearance, output: output.appendingPathComponent("codex-summary-\(language.rawValue).png"), scrollY: 260)

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
        print("Codex panel passed: 4-language sign-in-required/independent local data/consent routing/no signed-out cache, removed 7-day graph and 10-minute chart, compact first-viewport usage/composition/models, fixed bounds, separate account numeric summaries, removed recent-record and settings items, local UTC-today scope, hidden updates, stale/partial/unknown states, app runtime and safe metadata; synthetic only, no local-record or server access")
    }
}
