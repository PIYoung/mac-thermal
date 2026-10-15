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

    private static func sample(_ index: Int, seconds: Double? = nil) -> Snapshot {
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
                    writeBytesPerSecond: Double(index) * 500_000, deviceCount: 1)))
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func benchmark() {
        let panel = PanelController()
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
    private static func regressionChecks(defaults: UserDefaults) {
        let panel = PanelController()
        let window = DashboardWindow(controller: panel)
        window.setFrame(NSRect(x: 128, y: 256, width: PanelController.size.width,
            height: PanelController.size.height), display: false)
        let initialFrame = window.frame
        let initialSurfaceFrames = panel.probeSurfaceFrames
        let initialStrings = panel.probeStrings
        precondition(!window.isVisible)
        for index in 0...90 { panel.apply(sample(index)) }
        precondition(panel.probeStrings == initialStrings, "Hidden sampling must not format AppKit fields")
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
        precondition(Array(panel.probePresentedHistoryTimes.prefix(2)) == Array(hiddenTimes[1...2]))
        for _ in 0..<5 { panel.prepareForPresentation() }
        precondition(panel.probeHistoryTimes == hiddenTimes, "Presentation must not duplicate history")

        // No real window is shown. Only this test build can simulate visibility.
        panel.probeSetVisible(true)
        panel.probeSelectTab(1)
        let memoryAt90 = panel.probeStrings["memory"]
        precondition(memoryAt90 != initialStrings["memory"])
        panel.apply(sample(91))
        precondition(panel.probeStrings["memory"] != memoryAt90)
        precondition(panel.probeStrings["cpuPercent"] == "90%", "Inactive summary must remain untouched")
        precondition(panel.probePresentedCPUHistoryTimes == hiddenTimes[0], "Inactive CPU graph must not update its views")
        panel.probeSelectTab(2)
        precondition(panel.probeStrings["processes"] == L10n.format("조회 %d개 · 제외 %d개", 191, 1))
        panel.probeSelectTab(3)
        precondition(Array(panel.probePresentedHistoryTimes.suffix(2)) == Array(panel.probeHistoryTimes.suffix(2)))
        let diskAt91 = panel.probeStrings["disk"]
        panel.probeToggleSettings()
        panel.apply(sample(92))
        precondition(panel.probeStrings["disk"] == diskAt91, "Settings must not update hidden data tabs")
        panel.probeToggleSettings()
        precondition(panel.probeStrings["disk"] != diskAt91, "Closing settings must immediately show the latest sample")

        let timesBeforeLanguage = panel.probeHistoryTimes
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            panel.probeSelectTab(0)
            precondition(panel.probeStrings["thermal"] == ThermalStatus(.nominal).detail)
            panel.probeSelectTab(1)
            precondition(panel.probeStrings["memoryTotal"] == L10n.format("전체 %@", "64.0 GB"))
            panel.probeSelectTab(2)
            precondition(panel.probeStrings["processes"] == L10n.format("조회 %d개 · 제외 %d개", 192, 1))
            panel.probeSelectTab(3)
        }
        precondition(panel.probeHistoryTimes == timesBeforeLanguage, "Language and tab changes must not record samples")

        panel.probeSetVisible(false)
        L10n.setLanguage(.english, defaults: defaults)
        precondition(panel.probeHistoryTimes == timesBeforeLanguage)
        panel.apply(sample(95, seconds: 320))
        precondition(panel.probeHistoryTimes.allSatisfy { $0.count == 1 }, "A sleep-sized gap must discard history older than one minute")
        panel.prepareForPresentation()
        precondition(Array(panel.probePresentedHistoryTimes.suffix(2)) == Array(panel.probeHistoryTimes.suffix(2)))
        panel.probeSetVisible(true)
        panel.probeSelectTab(0)
        precondition(panel.probeStrings["cpuPercent"] == "95%", "Reopening must show the most recent hidden sample")
        precondition(panel.probeStrings["thermal"] == ThermalStatus(.nominal).detail)
        precondition(panel.probePresentedCPUHistoryTimes == panel.probeHistoryTimes[0])
        precondition(panel.probeCPUHistoryRuns.count == 1 && panel.probeCPUHistoryRuns[0].count == 1)
        precondition(window.frame == initialFrame && panel.probeSurfaceFrames == initialSurfaceFrames)
        precondition(PanelController.surfaceSize == NSSize(width: 380, height: 468))
        print("Panel hidden sampling, latest selected tab/reopen/settings, four languages, history retention/no duplicates, and fixed frame checks passed")
    }
    #endif

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain(["dashboardSelectedTabV2": 0,
            AppLanguage.defaultsKey: AppLanguage.korean.rawValue], forName: UserDefaults.argumentDomain)
        let suite = "local.mac-thermal.panel-probe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot isolate preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        L10n.setLanguage(.korean, defaults: defaults)
        #if PANEL_UPDATES_PROBE
        regressionChecks(defaults: defaults)
        #endif
        if CommandLine.arguments.contains("--benchmark") { benchmark() }
    }
}
