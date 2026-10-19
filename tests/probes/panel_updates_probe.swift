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

    private static func sample(_ index: Int, seconds: Double? = nil, gpu: GPUSnapshot? = nil) -> Snapshot {
        let elapsed = seconds ?? Double(index * 2)
        let process = ResourceProcess(name: "Fixture \(index)", pid: 1_000 + index,
            cpuPercent: Double(index % 100), memoryBytes: Double(index + 1) * 1_024 * 1_024)
        return Snapshot(cpuTemperature: Double(40 + index % 50), ssdTemperature: 42,
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
            for child in node.subviews where !child.isHidden {
                let container = node.bounds.insetBy(dx: -0.5, dy: -0.5)
                precondition(container.contains(child.frame), "Visible content outside its parent: \(type(of: child)) \(child.frame) in \(node.bounds)")
                if !(child is NSControl) && !(child is NSScrollView) { visit(child) }
            }
        }
        var canvasCount = 0
        func findCanvases(_ node: NSView) {
            if node.frame.width == 344 && ((280...320).contains(node.frame.height) || node.frame.height == 363) {
                precondition(node.bounds.size == node.frame.size)
                precondition(node.frame.maxY <= 429, "Resource content must remain above the footer divider")
                if !node.isHidden { canvasCount += 1; visit(node) }
            } else {
                node.subviews.forEach(findCanvases)
            }
        }
        findCanvases(root)
        precondition(canvasCount == 1, "Exactly one resource or settings content canvas must be visible")
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
            precondition(panel.probeTabLabels == ["CPU", "GPU", L10n.text("메모리"), "SSD", L10n.text("네트워크")])
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
            precondition(panel.probeMetricTitles == ["CPU", "GPU", "SSD", L10n.text("네트워크")])
            precondition(panel.probeMetricLabelsFit, "All four native checkbox labels must fit in every language")
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
        precondition(PanelController.surfaceSize == NSSize(width: 380, height: 468))
        print("Resource tab migration/persistence, embedded rankings, selected-tab-only updates, hidden histories, settings/reopen, four-language bounds, and fixed frame checks passed")
    }

    private static func menuMetricChecks(defaults: UserDefaults) {
        let all = Set(MenuBarMetric.allCases)
        precondition(MenuBarPreferences.load(defaults: defaults).visibleMetrics == all,
            "Fresh installs must show all four menu bar metrics")
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
        precondition(expected.isEmpty && callbacks.count == 4, "All four items can be switched off independently")
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
        precondition(expected == all && callbacks.count == 8)
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

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        #if PANEL_UPDATES_PROBE
        selectionChecks()
        withDefaults { defaults in
            L10n.setLanguage(.korean, defaults: defaults)
            gpuChecks(defaults: defaults)
        }
        withDefaults { defaults in
            L10n.setLanguage(.korean, defaults: defaults)
            menuMetricChecks(defaults: defaults)
        }
        withDefaults { defaults in
            L10n.setLanguage(.korean, defaults: defaults)
            regressionChecks(defaults: defaults)
        }
        #endif
        if CommandLine.arguments.contains("--benchmark") { benchmark() }
    }
}
