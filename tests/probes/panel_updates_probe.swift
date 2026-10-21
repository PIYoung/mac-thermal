import AppKit
import Foundation
import Darwin

// Fixtures never query metrics or login-item services.
enum LoginItemManager {
    struct State { let enabled: Bool; let requiresApproval: Bool; let title: String }
    static func state() -> State { State(enabled: false, requiresApproval: false, title: "Fixture") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
}

@main
enum PanelUpdatesProbe {
    private static let origin = Date(timeIntervalSince1970: 1_792_065_600)

    private static func sample(_ index: Int, seconds: Double? = nil, gpu: GPUSnapshot? = nil, cpuTemperature: Double? = nil, ssdTemperature: Double = 42) -> Snapshot {
        let elapsed = seconds ?? Double(index * 2)
        let process = ResourceProcess(name: "Fixture \(index)", pid: 1_000 + index,
            cpuPercent: Double(index % 100), memoryBytes: Double(index + 1) * 1_024 * 1_024)
        return Snapshot(cpuTemperature: cpuTemperature ?? Double(40 + index % 50), ssdTemperature: ssdTemperature,
            cpuUsage: Double(index % 100), upload: Double(index) * 1_000,
            download: Double(index) * 2_000, interfaces: 1, cpuSensors: 8, ssdSensors: 2,
            thermal: ThermalStatus(.nominal), time: origin.addingTimeInterval(elapsed),
            uptime: 4_000 + elapsed,
            resources: ResourceSnapshot(
                memory: MemorySnapshot(totalBytes: 64 * 1_024 * 1_024 * 1_024,
                    usedBytes: Double(index + 1) * 256 * 1_024 * 1_024,
                    compressedBytes: 512 * 1_024 * 1_024, swapUsedBytes: 0, pressureLevel: 0),
                processes: ProcessSnapshot(cpuTop: [process], memoryTop: [process], cpuReady: true,
                    readableCount: 100 + index, skippedCount: 1, available: true),
                disk: DiskSnapshot(totalBytes: 512_000_000_000,
                    availableBytes: 256_000_000_000 - Double(index) * 1_000_000_000,
                    readBytesPerSecond: Double(index) * 1_000_000,
                    writeBytesPerSecond: Double(index) * 500_000, deviceCount: 1),
                gpu: gpu ?? GPUSnapshot(utilizationPercent: Double(index % 100), model: "Apple M4 Pro", coreCount: 20)))
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func withDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let suite = "local.mac-thermal.panel-probe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot isolate preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        return body(defaults)
    }

    private static func benchmark() {
        #if PANEL_UPDATES_PROBE
        let suite = "local.mac-thermal.panel-benchmark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot isolate benchmark preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = PanelController(defaults: defaults)
        #else
        let panel = PanelController()
        #endif
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PanelController.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = panel
        precondition(!window.isVisible)
        let batches = (0..<9).map { batch in
            (0..<600).map { sample($0 % 200, seconds: Double((30 + batch * 600 + $0) * 2)) }
        }
        for index in 0..<30 { panel.apply(sample(index)) }
        var measurements: [Double] = []
        for samples in batches {
            autoreleasepool {
                let start = cpuTime()
                for fixture in samples { panel.apply(fixture) }
                measurements.append((cpuTime() - start) * 1_000_000 / Double(samples.count))
            }
        }
        let median = measurements.sorted()[measurements.count / 2]
        #if PANEL_UPDATES_BASELINE
        let label = "baseline"
        #else
        let label = "optimized"
        #endif
        print(String(format: "Hidden panel apply %@: median %.3f CPU µs/sample (9 × 600 synthetic samples)", label, median))
    }

    #if PANEL_UPDATES_PROBE
    private static let oldTabKey = "dashboardSelectedTabV2"
    private static let resourceTabKey = "dashboardSelectedResourceTabV3"
    private static let stableTabKey = "dashboardSelectedResourceTabV4"
    private static let stableTabs = ["cpu", "gpu", "memory", "ssd", "network"]

    private static func selectionChecks() {
        // Saved indexes changed meaning. Migrate each resource to a stable name.
        for (old, expected) in [(0, 0), (1, 2), (2, 0), (3, 3), (-1, 0), (99, 0)] {
            withDefaults { defaults in
                defaults.set(old, forKey: oldTabKey)
                let panel = PanelController(defaults: defaults)
                _ = panel.view
                precondition(panel.probeSelectedTab == expected, "V2 selection must migrate to the same resource")
                precondition(defaults.string(forKey: stableTabKey) == stableTabs[expected])
            }
        }
        for (old, expected) in [(0, 0), (1, 2), (2, 3), (3, 4), (-1, 0), (99, 0)] {
            withDefaults { defaults in
                defaults.set(3, forKey: oldTabKey)
                defaults.set(old, forKey: resourceTabKey)
                let panel = PanelController(defaults: defaults)
                _ = panel.view
                precondition(panel.probeSelectedTab == expected, "V3 takes precedence and must retain the same resource")
                precondition(defaults.string(forKey: stableTabKey) == stableTabs[expected])
            }
        }
        for current in stableTabs.indices {
            withDefaults { defaults in
                defaults.set(3, forKey: oldTabKey)
                defaults.set(2, forKey: resourceTabKey)
                defaults.set(stableTabs[current], forKey: stableTabKey)
                let panel = PanelController(defaults: defaults)
                _ = panel.view
                precondition(panel.probeSelectedTab == current, "Stable selection takes precedence over legacy keys")
                let next = (current + 1) % stableTabs.count
                panel.probeSelectTab(next)
                precondition(defaults.string(forKey: stableTabKey) == stableTabs[next])
                let reopened = PanelController(defaults: defaults)
                _ = reopened.view
                precondition(reopened.probeSelectedTab == next, "A new controller must restore the last selected resource")
            }
        }
        for invalid in ["", "old-resource", "99"] {
            withDefaults { defaults in
                defaults.set(invalid, forKey: stableTabKey)
                let panel = PanelController(defaults: defaults)
                _ = panel.view
                precondition(panel.probeSelectedTab == 0)
            }
        }
        withDefaults { defaults in
            let panel = PanelController(defaults: defaults)
            _ = panel.view
            precondition(panel.probeSelectedTab == 0, "First launch defaults to CPU")
        }
    }

    private static func checkContentBounds(_ root: NSView) {
        // Inspect our fixed resource canvases, excluding AppKit's private material
        // and control subviews. This catches a card or label crossing its parent.
        func visit(_ node: NSView) {
            if let scroll = node as? NSScrollView, let document = scroll.documentView {
                precondition(document.frame.width <= scroll.contentSize.width + 0.5, "Settings must scroll vertically without horizontal clipping")
                visit(document)
                return
            }
            for child in node.subviews where !child.isHidden {
                let container = node.bounds.insetBy(dx: -0.5, dy: -0.5)
                precondition(container.contains(child.frame), "Visible content outside its parent: \(type(of: child)) \(child.frame) in \(node.bounds)")
                if !(child is NSControl) && !(child is NSScrollView) { visit(child) }
            }
        }
        var canvasCount = 0
        func findCanvases(_ node: NSView) {
            if node.frame.width == 308 && (node.frame.height == 277 || node.frame.height == 310) {
                precondition(node.bounds.size == node.frame.size)
                precondition(node.frame.maxY <= 379, "Resource content must remain above the footer divider")
                if !node.isHidden { canvasCount += 1; visit(node) }
            } else {
                node.subviews.forEach(findCanvases)
            }
        }
        findCanvases(root)
        precondition(canvasCount == 1, "Exactly one resource or settings content canvas must be visible")
    }

    private static func surfaceHitChecks() {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        let group = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        container.addSubview(group)
        let firstGlass = FlippedView()
        let secondGlass = FlippedView()
        let firstButton = NSButton(frame: NSRect(x: 328, y: 100, width: 12, height: 20))
        let secondButton = NSButton(frame: NSRect(x: 0, y: 100, width: 18, height: 20))
        firstGlass.addSubview(firstButton)
        secondGlass.addSubview(secondButton)
        let first = PanelSurfaceHost(glass: firstGlass)
        let second = PanelSurfaceHost(glass: secondGlass, surfaceSize: NSSize(width: 300, height: 420))
        first.frame.origin = NSPoint(x: 60, y: 40)
        second.frame.origin = NSPoint(x: 412, y: 40)
        group.addSubview(first)
        group.addSubview(second)
        precondition(first.frame.size == NSSize(width: 388, height: 468))
        precondition(second.frame.size == NSSize(width: 348, height: 468))
        precondition(first.hitTest(NSPoint(x: 65, y: 100)) == nil, "Transparent margin must not consume sibling input")
        precondition(second.hitTest(NSPoint(x: 420, y: 174)) == nil, "The front host's left shadow overlaps its sibling body")
        precondition(group.hitTest(NSPoint(x: 420, y: 174)) === firstButton,
            "A control under the sibling shadow must receive the original click")
        precondition(group.hitTest(NSPoint(x: 440, y: 174)) === secondButton,
            "Both panel surfaces must remain interactive")
        second.isHidden = true
        precondition(group.hitTest(NSPoint(x: 420, y: 174)) === firstButton)
        print("Shared glass hosts passed: independent sizes, parent-relative coordinates, overlapping shadow pass-through, sibling controls and hidden host")
    }

    private static func groupedWindowChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        let companion = NSViewController()
        companion.view = PanelSurfaceHost(glass: FlippedView(), surfaceSize: NSSize(width: 300, height: 420))
        let window = DashboardWindow(controller: panel, companion: companion)
        let anchor = NSRect(x: 1_100, y: 880, width: 80, height: 24)
        let horizontal = window.probeConfigure(anchor: anchor,
            screen: NSRect(x: 0, y: 0, width: 1_440, height: 880), companion: true)
        precondition(!window.isVisible && !horizontal.scrollsVertically && !companion.view.isHidden)
        for surface in [horizontal.primarySurface, horizontal.companionSurface!] {
            precondition(window.probeContainsCanvasPoint(NSPoint(x: surface.midX, y: surface.midY)))
        }
        precondition(!window.probeContainsCanvasPoint(NSPoint(x: horizontal.primarySurface.midX, y: 4)))
        precondition(horizontal.companionSurface!.maxX + 12 == horizontal.primarySurface.minX, "Codex stays on the left")
        let gapX = (horizontal.companionSurface!.maxX + horizontal.primarySurface.minX) / 2
        precondition(!window.probeContainsCanvasPoint(NSPoint(x: gapX, y: 100)), "The inter-panel gap must dismiss the pair")
        let fixedFrame = window.frame
        panel.apply(sample(73))
        panel.probeToggleSettings()
        panel.probeToggleSettings()
        precondition(window.frame == fixedFrame, "Samples and settings must never move an open pair")

        let stacked = window.probeConfigure(anchor: NSRect(x: 220, y: 600, width: 80, height: 24),
            screen: NSRect(x: 0, y: 0, width: 600, height: 600), companion: true)
        precondition(stacked.scrollsVertically)
        window.probeScroll(to: NSPoint(x: 0, y: 200))
        for surface in [stacked.primarySurface, stacked.companionSurface!] {
            precondition(window.probeContainsCanvasPoint(NSPoint(x: surface.midX, y: surface.midY)),
                "Glass hit testing must convert the scrolled document coordinates")
            precondition(!window.probeContainsCanvasPoint(NSPoint(x: 4, y: surface.midY)),
                "Scrolling must not turn the transparent margin into an interactive surface")
        }
        let gapY = (stacked.primarySurface.maxY + stacked.companionSurface!.minY) / 2
        precondition(!window.probeContainsCanvasPoint(NSPoint(x: 100, y: gapY)))
        precondition(window.probeContainsCanvasPoint(NSPoint(x: stacked.documentSize.width - 4, y: gapY)),
            "The actual overlay scroller remains interactive in the right margin")
        _ = window.probeConfigure(anchor: anchor,
            screen: NSRect(x: 0, y: 0, width: 1_440, height: 880), companion: false)
        precondition(companion.view.isHidden && panel.probeSelectedTab == 0)
        _ = window.probeConfigure(anchor: anchor,
            screen: NSRect(x: 0, y: 0, width: 1_440, height: 880), companion: true)
        precondition(!companion.view.isHidden && !window.isVisible,
            "Resource-only and paired layouts must safely reparent the same views without ordering a window")
        print("Paired dashboard passed: fixed updates/settings, sibling glass hits, gap/margin dismissal after scrolling, and safe layout reattachment")
    }

    private static func regressionChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        window.setFrame(NSRect(x: 128, y: 256, width: PanelController.size.width,
            height: PanelController.size.height), display: false)
        let initialFrame = window.frame
        let initialSurfaceFrames = panel.probeSurfaceFrames
        let initialStrings = panel.probeStrings
        let initialRankings = panel.probeRankingTexts
        precondition(!window.isVisible)
        for index in 0...90 { panel.apply(sample(index)) }
        precondition(panel.probeStrings == initialStrings, "Hidden sampling must not format AppKit fields")
        precondition(panel.probeRankingTexts == initialRankings, "Hidden sampling must not format either ranking")
        let hiddenTimes = panel.probeHistoryTimes
        precondition(hiddenTimes.allSatisfy { $0.count == 31 }, "All histories must retain the last minute while hidden")
        precondition(hiddenTimes[0].first == 4_120 && hiddenTimes[0].last == 4_180)
        precondition(hiddenTimes.dropFirst().allSatisfy {
            $0.first == origin.timeIntervalSince1970 + 120 && $0.last == origin.timeIntervalSince1970 + 180
        })
        panel.prepareForPresentation()
        precondition(panel.probeStrings["cpuPercent"] == "90%")
        precondition(panel.probePresentedCPUHistoryTimes == hiddenTimes[0])
        precondition(panel.probeStrings["memory"] == initialStrings["memory"])
        precondition(panel.probeStrings["disk"] == initialStrings["disk"])
        precondition(panel.probeStrings["upload"] == initialStrings["upload"])
        precondition(panel.probeRankingTexts["cpu"]?.contains(where: { $0.contains("Fixture 90 · ") }) == true)
        precondition(panel.probeRankingTexts["memory"] == initialRankings["memory"])
        precondition(panel.probePresentedHistoryTimes.allSatisfy(\.isEmpty), "CPU presentation must not update SSD or network graph views")
        for _ in 0..<5 { panel.prepareForPresentation() }
        precondition(panel.probeHistoryTimes == hiddenTimes, "Presentation must not duplicate history")

        // No real window is shown. Only this test build can simulate visibility.
        panel.probeSetVisible(true)
        panel.probeSelectTab(2)
        let memoryAt90 = panel.probeStrings["memory"]
        let cpuRankingAt90 = panel.probeRankingTexts["cpu"]
        precondition(memoryAt90 != initialStrings["memory"])
        precondition(panel.probeRankingTexts["memory"]?.contains(where: { $0.contains("Fixture 90 · ") }) == true)
        panel.apply(sample(91))
        precondition(panel.probeStrings["memory"] != memoryAt90)
        precondition(panel.probeRankingTexts["memory"]?.contains(where: { $0.contains("Fixture 91 · ") }) == true)
        precondition(panel.probeRankingTexts["cpu"] == cpuRankingAt90, "Memory sampling must not update CPU ranking views")
        precondition(panel.probeStrings["cpuPercent"] == "90%", "Inactive CPU must remain untouched")
        precondition(panel.probePresentedCPUHistoryTimes == hiddenTimes[0], "Inactive CPU graph must not update its views")
        precondition(panel.probeStrings["memoryProcesses"] == L10n.format("조회 %d개 · 제외 %d개", 191, 1))

        panel.probeSelectTab(3)
        precondition(Array(panel.probePresentedHistoryTimes.suffix(2)) == Array(panel.probeHistoryTimes.suffix(2)))
        precondition(panel.probePresentedHistoryTimes.prefix(2).allSatisfy(\.isEmpty))
        let diskAt91 = panel.probeStrings["disk"]
        panel.probeToggleSettings()
        panel.apply(sample(92))
        precondition(panel.probeStrings["disk"] == diskAt91, "Settings must not update hidden data tabs")
        panel.probeToggleSettings()
        precondition(panel.probeStrings["disk"] != diskAt91, "Closing settings must immediately show the latest sample")
        let diskAt92 = panel.probeStrings["disk"]
        let diskHistoryAt92 = Array(panel.probePresentedHistoryTimes.suffix(2))
        panel.probeSelectTab(4)
        let uploadAt92 = panel.probeStrings["upload"]
        panel.apply(sample(93))
        precondition(panel.probeStrings["upload"] != uploadAt92)
        precondition(panel.probeStrings["disk"] == diskAt92)
        precondition(Array(panel.probePresentedHistoryTimes.suffix(2)) == diskHistoryAt92)
        precondition(Array(panel.probePresentedHistoryTimes.prefix(2)) == Array(panel.probeHistoryTimes[1...2]))

        let timesBeforeLanguage = panel.probeHistoryTimes
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            precondition(panel.probeTabLabels == ["CPU", "GPU", L10n.text("메모리"), "SSD", L10n.text("통신")])
            for label in panel.probeTabLabels {
                let measured = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
                precondition(measured <= 308 / 5 - 8, "Compact tabs must fit at the original 11pt font in every language: \(label)")
            }
            for tab in 0..<5 {
                panel.probeSelectTab(tab)
                panel.view.layoutSubtreeIfNeeded()
                checkContentBounds(panel.view)
                switch tab {
                case 0:
                    precondition(panel.probeStrings["cpuPercent"] == "93%")
                    precondition(panel.probeStrings["cpuProcesses"] == L10n.format("조회 %d개 · 제외 %d개", 193, 1))
                    precondition(panel.probeRankingTexts["cpu"]?.contains(where: { $0.contains("Fixture 93 · ") }) == true)
                case 1:
                    precondition(panel.probeStrings["gpuPercent"] == "93%")
                    precondition(panel.probeStrings["gpuModel"] == "Apple M4 Pro")
                    precondition(panel.probeStrings["gpuCores"] == L10n.format("%d코어", 20))
                    precondition(panel.probePresentedGPUHistoryTimes == panel.probeGPUHistoryTimes)
                case 2:
                    precondition(panel.probeStrings["memoryTotal"] == L10n.format("전체 %@", "64.0 GB"))
                    precondition(panel.probeStrings["memoryProcesses"] == L10n.format("조회 %d개 · 제외 %d개", 193, 1))
                    precondition(panel.probeRankingTexts["memory"]?.contains(where: { $0.contains("Fixture 93 · ") }) == true)
                default: break
                }
            }
            panel.probeToggleSettings()
            checkContentBounds(panel.view)
            precondition(panel.probeMetricTitles == ["CPU", "GPU", "SSD", L10n.text("네트워크"), "Codex"])
            precondition(panel.probeMetricLabelsFit, "All five native checkbox labels must fit in every language")
            precondition(panel.probeVisibleMetrics == Set(MenuBarMetric.allCases))
            panel.probeClickMetric(.cpu)
            precondition(!panel.probeVisibleMetrics.contains(.cpu) && !panel.probeCPUStyleEnabled)
            panel.probeClickMetric(.cpu)
            precondition(panel.probeVisibleMetrics.contains(.cpu) && panel.probeCPUStyleEnabled)
            panel.probeToggleSettings()
        }
        precondition(panel.probeHistoryTimes == timesBeforeLanguage, "Language and tab changes must not record samples")

        panel.probeSetVisible(false)
        L10n.setLanguage(.english, defaults: defaults)
        precondition(panel.probeHistoryTimes == timesBeforeLanguage)
        panel.apply(sample(95, seconds: 320))
        precondition(panel.probeHistoryTimes.allSatisfy { $0.count == 1 }, "A sleep-sized gap must discard history older than one minute")
        panel.prepareForPresentation()
        precondition(Array(panel.probePresentedHistoryTimes.prefix(2)) == Array(panel.probeHistoryTimes[1...2]))
        panel.probeSetVisible(true)
        panel.probeSelectTab(0)
        precondition(panel.probeStrings["cpuPercent"] == "95%", "Reopening must show the most recent hidden sample")
        precondition(panel.probeRankingTexts["cpu"]?.contains(where: { $0.contains("Fixture 95 · ") }) == true)
        precondition(panel.probePresentedCPUHistoryTimes == panel.probeHistoryTimes[0])
        precondition(panel.probeCPUHistoryRuns.count == 1 && panel.probeCPUHistoryRuns[0].count == 1)
        precondition(window.frame == initialFrame && panel.probeSurfaceFrames == initialSurfaceFrames)
        precondition(PanelController.surfaceSize == NSSize(width: 340, height: 420))
        print("Resource tab migration/persistence, embedded rankings, selected-tab-only updates, hidden histories, settings/reopen, four-language bounds, and fixed frame checks passed")
    }

    private static func codexRecordsSettingsChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        // Snapshot state received before view creation must populate the setting.
        panel.updateCodexRecords(.partial)
        _ = panel.view
        var changes: [Bool] = []
        panel.codexRecordsEnabledChanged = { changes.append($0) }
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            precondition(panel.probeCodexRecordsEnabled)
            precondition(panel.probeCodexRecordsStatus == L10n.text("일부 기록만 집계"))
            precondition(panel.probeCodexPrivacyFits)
            panel.probeToggleSettings()
            checkContentBounds(panel.view)
            panel.probeToggleSettings()
            precondition(changes.isEmpty, "Rendering, language changes and settings navigation must preserve consent")
        }
        panel.probeSetCodexRecordsEnabled(false)
        precondition(changes == [false] && !panel.probeCodexRecordsEnabled)
        panel.probeSetCodexRecordsEnabled(false)
        precondition(changes == [false], "An unchanged switch must not duplicate callbacks")
        panel.probeSetCodexRecordsEnabled(true)
        precondition(changes == [false, true] && panel.probeCodexRecordsEnabled)
        precondition(panel.probeCodexRecordsStatus == L10n.text("로컬 기록 확인 중"))
        panel.updateCodexRecords(.ready)
        precondition(changes == [false, true], "Collector snapshots must never send switch actions")
        precondition(panel.probeCodexRecordsStatus == L10n.text("읽기 전용 · 외부 전송 없음"))
        var alertActions: [Bool] = []
        panel.codexResetNotificationsChanged = { alertActions.append($0) }
        for language in AppLanguage.allCases {
            panel.updateCodexResetNotifications(enabled: false, statusKey: "꺼짐 · 기본값", requesting: false)
            L10n.setLanguage(language, defaults: defaults)
            panel.probeToggleSettings(); checkContentBounds(panel.view); panel.probeToggleSettings()
            precondition(!panel.probeResetNotificationsEnabled && panel.probeResetNotificationsCanChange)
            precondition(panel.probeResetNotificationsStatus == L10n.text("꺼짐 · 기본값"))
            precondition(alertActions.isEmpty, "Layout and language must never request notification permission")
        }
        panel.probeSetResetNotifications(true)
        precondition(alertActions == [true], "Only explicit switch action requests enable")
        panel.updateCodexResetNotifications(enabled: false, statusKey: "알림 권한 확인 중", requesting: true)
        precondition(!panel.probeResetNotificationsCanChange)
        panel.updateCodexResetNotifications(enabled: true, statusKey: "켜짐 · 서버 갱신 확인 후 알림", requesting: false)
        precondition(panel.probeResetNotificationsEnabled && panel.probeResetNotificationsCanChange)
        panel.probeSetResetNotifications(false)
        precondition(alertActions == [true, false], "Explicit off is delivered independently of local record reading")
        print("Moved Codex record setting passed: pre-load state, four-language privacy, native switch callbacks, no consent change on render/navigation")
    }

    private static func cpuStyleChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        let frame = window.frame
        panel.probeToggleSettings()
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            precondition(panel.probeCPUStyleTitles == MenuBarAnimationStyle.allCases.map(\.title))
            precondition(panel.probeCPUStyleTitles.count == 10)
            for style in MenuBarAnimationStyle.allCases {
                panel.probeSelectCPUStyle(style)
                precondition(panel.probeMenuBarPreferences.style == style)
                precondition(MenuBarPreferences.load(defaults: defaults).style == style)
                panel.probeToggleSettings(); panel.probeToggleSettings()
                precondition(panel.probeMenuBarPreferences.style == style)
                precondition(window.frame == frame)
            }
        }
        print("CPU styles passed: ten localized options, real native actions, persistence/reopen and fixed panel bounds in four languages")
    }

    private static func menuMetricChecks(defaults: UserDefaults) {
        let all = Set(MenuBarMetric.allCases)
        precondition(MenuBarPreferences.load(defaults: defaults).visibleMetrics == all,
            "Fresh installs select resources and the conditional Codex tile")
        let original = MenuBarPreferences(style: .orbit, motionEnabled: true, intensity: 1.35, visibleMetrics: all)
        original.save(defaults: defaults)
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        let frame = window.frame
        let surfaceFrames = panel.probeSurfaceFrames
        panel.probeToggleSettings()
        var callbacks: [MenuBarPreferences] = []
        panel.menuBarPreferencesChanged = { callbacks.append($0) }
        var expected = all
        func checkSelection() {
            let preferences = panel.probeMenuBarPreferences
            precondition(panel.probeVisibleMetrics == expected)
            precondition(preferences.visibleMetrics == expected)
            precondition(MenuBarPreferences.load(defaults: defaults) == preferences,
                "A real checkbox action must persist immediately")
            precondition(callbacks.last == preferences, "A real checkbox action must notify the menu renderer immediately")
            precondition(preferences.style == original.style && preferences.motionEnabled == original.motionEnabled
                && preferences.intensity == original.intensity, "Visibility changes must retain animation preferences")
            precondition(panel.probeCPUStyleEnabled == expected.contains(.cpu))
            precondition(panel.probeMotionControlEnabled == !expected.isEmpty)
            precondition(panel.probeIntensityControlEnabled == !expected.isEmpty)
            precondition(window.frame == frame && panel.probeSurfaceFrames == surfaceFrames)
            checkContentBounds(panel.view)
        }
        for metric in MenuBarMetric.allCases {
            expected.remove(metric)
            panel.probeClickMetric(metric)
            checkSelection()
        }
        precondition(expected.isEmpty && callbacks.count == all.count, "All menu items can be switched off independently")
        let reopened = PanelController(defaults: defaults)
        _ = reopened.view
        reopened.probeToggleSettings()
        precondition(reopened.probeVisibleMetrics.isEmpty, "An explicitly empty selection must survive reopening")
        precondition(!reopened.probeMotionControlEnabled && !reopened.probeIntensityControlEnabled)
        precondition(reopened.probeMenuBarPreferences.motionEnabled,
            "Disabling unavailable controls must preserve the user's motion preference")
        for metric in MenuBarMetric.allCases {
            expected.insert(metric)
            panel.probeClickMetric(metric)
            checkSelection()
        }
        precondition(expected == all && callbacks.count == all.count * 2)
        print("Native menu checkbox actions passed: independent visibility, immediate callbacks/persistence, empty selection/reopen, preserved motion preferences, and fixed bounds")
    }

    private static func gpuChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        let frame = window.frame
        let surfaceFrames = panel.probeSurfaceFrames
        let initialGPU = panel.probeStrings["gpuPercent"]
        for index in 0...4 { panel.apply(sample(index)) }
        precondition(panel.probeGPUHistoryTimes.count == 5, "Hidden GPU history must collect alongside CPU")
        precondition(panel.probeStrings["gpuPercent"] == initialGPU, "Hidden GPU sampling must not format views")
        panel.prepareForPresentation()
        precondition(panel.probePresentedGPUHistoryTimes.isEmpty, "CPU presentation must not touch the GPU graph")
        panel.probeSetVisible(true)
        panel.probeSelectTab(1)
        precondition(panel.probeStrings["gpuPercent"] == "4%")
        precondition(panel.probePresentedGPUHistoryTimes == panel.probeGPUHistoryTimes)
        let cpu = panel.probeStrings["cpuPercent"]
        panel.apply(sample(5, gpu: .pending))
        precondition(panel.probeStrings["gpuPercent"] == L10n.text("정보 없음"))
        precondition(panel.probeStrings["gpuModel"] == L10n.text("정보 없음"))
        precondition(panel.probeStrings["gpuCores"] == L10n.text("정보 없음"))
        precondition(panel.probeStrings["gpuDetail"] == L10n.text("이 Mac에서 GPU 사용률을 읽을 수 없습니다"))
        precondition(panel.probeStrings["cpuPercent"] == cpu, "GPU sampling must not touch inactive CPU fields")
        panel.apply(sample(6))
        precondition(panel.probeGPUHistoryRuns.count == 2, "Missing GPU samples must disconnect graph runs")
        let gpuAt6 = panel.probeStrings["gpuPercent"]
        panel.probeSelectTab(0)
        panel.apply(sample(7))
        precondition(panel.probeStrings["gpuPercent"] == gpuAt6, "Inactive GPU fields must remain untouched")
        panel.probeSelectTab(1)
        precondition(panel.probeStrings["gpuPercent"] == "7%", "Selecting GPU must show the latest hidden sample")
        for invalid in [Double.nan, Double.infinity, -1, 101] {
            panel.apply(sample(8, gpu: GPUSnapshot(utilizationPercent: invalid, model: "", coreCount: 0)))
            precondition(panel.probeStrings["gpuPercent"] == L10n.text("정보 없음"))
            precondition(panel.probeStrings["gpuModel"] == L10n.text("정보 없음"))
            precondition(panel.probeStrings["gpuCores"] == L10n.text("정보 없음"))
        }
        panel.apply(sample(9, seconds: 320))
        precondition(panel.probeGPUHistoryTimes.count == 1, "GPU history must expire across sleep-sized gaps")
        precondition(panel.probeGPUHistoryRuns.count == 1 && panel.probeGPUHistoryRuns[0].count == 1)
        precondition(window.frame == frame && panel.probeSurfaceFrames == surfaceFrames)
        print("GPU hidden sampling, selected-tab-only updates, unavailable/invalid values, history gaps, and fixed frame checks passed")
    }
    #endif

    private static func componentTemperatureChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        let frame = window.frame
        let surfaces = panel.probeSurfaceFrames
        panel.probeSetVisible(true)
        var fixture = sample(20)
        fixture.gpuTemperature = 100; fixture.memoryProximityTemperature = 85
        fixture.gpuSensors = 8; fixture.memoryProximitySensors = 2
        panel.probeSelectTab(0)
        panel.apply(fixture)
        let cpuBefore = panel.probeStrings["cpu"]
        panel.probeSelectTab(1)
        precondition(panel.probeStrings["gpuTemperature"] == "100 °C")
        precondition(panel.probeTemperatureColors[1] == NSColor.systemRed)
        precondition(panel.probeStrings["cpu"] == cpuBefore)
        panel.probeSelectTab(2)
        precondition(panel.probeStrings["memoryTemperature"] == "85 °C")
        precondition(panel.probeTemperatureColors[2] == NSColor.systemRed)
        precondition(panel.probeTemperatureTooltips[1].contains(L10n.text("메모리 주변 센서 %d개 중 최댓값 · 메모리 칩 내부 온도가 아닙니다").components(separatedBy: " · ").last!))
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            panel.probeSelectTab(1); checkContentBounds(panel.view)
            precondition(panel.probeThermalLabelsFit, "GPU thermal labels must fit in all languages")
            panel.probeSelectTab(2); checkContentBounds(panel.view)
            precondition(panel.probeThermalLabelsFit, "Memory nearby temperature and total capacity must fit in all languages")
            precondition(panel.probeStrings["memoryTemperatureTitle"] == L10n.text("메모리 주변 온도"))
        }
        for invalid: Double? in [nil, .nan, .infinity, 0, -1, 131] {
            fixture.gpuTemperature = invalid; fixture.memoryProximityTemperature = invalid
            panel.apply(fixture)
            precondition(panel.probeStrings["memoryTemperature"] == "— °C" && panel.probeTemperatureColors[2] == NSColor.labelColor)
            panel.probeSelectTab(1)
            precondition(panel.probeStrings["gpuTemperature"] == "— °C" && panel.probeTemperatureColors[1] == NSColor.labelColor)
            panel.probeSelectTab(2)
        }
        fixture.gpuTemperature = 70; fixture.memoryProximityTemperature = 65
        panel.apply(fixture)
        precondition(panel.probeTemperatureColors[2] == NSColor.labelColor)
        let memoryBefore = panel.probeStrings["memoryTemperature"]
        panel.probeSelectTab(1)
        precondition(panel.probeTemperatureColors[1] == NSColor.labelColor)
        fixture.memoryProximityTemperature = 80; fixture.gpuTemperature = 95
        panel.apply(fixture)
        precondition(panel.probeTemperatureColors[1] == NSColor.systemOrange)
        precondition(panel.probeStrings["memoryTemperature"] == memoryBefore, "Inactive memory tab must not format values")
        panel.probeSelectTab(2)
        precondition(panel.probeTemperatureColors[2] == NSColor.systemOrange)
        precondition(window.frame == frame && panel.probeSurfaceFrames == surfaces)
        panel.probeSetVisible(false)
        let hidden = panel.probeStrings
        fixture.gpuTemperature = 110; panel.apply(fixture)
        precondition(panel.probeStrings == hidden, "Hidden panels must not format temperature fields")
        L10n.setLanguage(.korean, defaults: defaults)
        print("Component temperature panels passed: independent warm/hot/recovery, invalid/missing values, memory proximity label and explanation, four-language fit, selected-tab/hidden updates, fixed frames")
    }

    private static func fanChecks(defaults: UserDefaults) {
        let panel = PanelController(defaults: defaults)
        panel.prepareForPresentation()
        panel.probeSetVisible(true)
        panel.probeSelectTab(0)
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let scenarios: [([Double?]?, String)] = [
                (nil, "팬 정보 없음"), ([], "팬 없음"), ([0, 0], "정지"),
                ([nil, 0], "팬 읽기 불가"), ([1800, 2100], "회전 중"), ([nil, 2000], "회전 중")]
            for (rpms, state) in scenarios {
                var fixture = sample(20); fixture.fans = FanSnapshot(rpms: rpms)
                panel.apply(fixture)
                precondition(panel.probeStrings["fans"] == fixture.fans.compact)
                precondition(fixture.fans.state == L10n.text(state))
                checkContentBounds(panel.view)
            }
        }
        L10n.setLanguage(.korean, defaults: defaults)
        panel.apply(sample(20, cpuTemperature: 100))
        precondition(panel.probeStrings["thermal"] == "CPU 온도 높음")
        panel.probeSelectTab(3)
        panel.apply(sample(20, ssdTemperature: 70))
        precondition(panel.probeStrings["ssdWarning"] == "SSD 온도 높음")
        panel.apply(sample(20))
        precondition(panel.probeStrings["ssdWarning"] == "SSD 온도")
        panel.probeSelectTab(0)
        precondition(FanSnapshot(rpms: [.nan, -1, 30001]).rpms!.allSatisfy { $0 == nil })
        precondition(FanSnapshot(rpms: Array(repeating: 0, count: 9)).rpms == nil)
        let before = panel.probeStrings["fans"]
        panel.probeSelectTab(1)
        var fixture = sample(22); fixture.fans = FanSnapshot(rpms: [1234])
        panel.apply(fixture)
        precondition(panel.probeStrings["fans"] == before, "Hidden CPU tab must not format fan fields")
        panel.probeSelectTab(0)
        precondition(panel.probeStrings["fans"] == fixture.fans.compact)
        print("Fan UI passed: unavailable/absent/stopped/partial/running, four languages, fixed bounds, selected-tab updates")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        #if PANEL_UPDATES_PROBE
        withDefaults { defaults in componentTemperatureChecks(defaults: defaults) }
        withDefaults { defaults in fanChecks(defaults: defaults) }
        selectionChecks()
        surfaceHitChecks()
        withDefaults { defaults in groupedWindowChecks(defaults: defaults) }
        withDefaults { defaults in
            L10n.setLanguage(.korean, defaults: defaults)
            gpuChecks(defaults: defaults)
        }
        withDefaults { defaults in
            L10n.setLanguage(.korean, defaults: defaults)
            codexRecordsSettingsChecks(defaults: defaults)
        menuMetricChecks(defaults: defaults)
        }
        withDefaults { defaults in cpuStyleChecks(defaults: defaults) }
        withDefaults { defaults in
            L10n.setLanguage(.korean, defaults: defaults)
            regressionChecks(defaults: defaults)
        }
        #endif
        if CommandLine.arguments.contains("--benchmark") { benchmark() }
    }
}
