import AppKit
import Foundation
import Darwin

// No collector, account, real model, notification or application is invoked.
enum LoginItemManager {
    struct State { let enabled: Bool; let requiresApproval: Bool; let title: String }
    static func state() -> State { .init(enabled: false, requiresApproval: false, title: "Fixture") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
}
final class AdviceFixtureEngine: OnDeviceAdviceGenerating {
    private let lock = NSLock()
    private var count = 0
    var available: AdviceModelAvailability = .ready
    var delay: UInt64 = 1_000_000
    var ignoresCancellation = false
    var invalid = false
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func availability(language: AppLanguage) -> AdviceModelAvailability { available }
    private func record() { lock.lock(); count += 1; lock.unlock() }
    func generate(_ report: HealthAdviceReport) async throws -> OnDeviceAdviceText {
        record()
        if ignoresCancellation { await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(delay) / 1_000_000_000) { continuation.resume() }
        } }
        else { try await Task.sleep(nanoseconds: delay) }
        return OnDeviceAdviceText(summary: invalid ? "sudo kill 123" : "측정값을 확인했어요",
            explanation: "원인은 이 수치만으로 확정할 수 없어요", supportingFacts: [report.facts[0].id])
    }
}

@main
struct HealthAdviceProbe {
    static func sample(_ time: Double = 0, cpu: Double? = 65, gpu: Double? = 60,
                       nearby: Double? = 50, pressure: Int? = 0, free: Double? = 500,
                       thermal: ProcessInfo.ThermalState = .nominal) -> Snapshot {
        let process = ResourceProcess(name: "PRIVATE_PROCESS_DO_NOT_SEND", pid: 111, cpuPercent: 90, memoryBytes: 500)
        return Snapshot(cpuTemperature: cpu, ssdTemperature: 42, cpuUsage: 70, upload: 1000, download: 2000,
            interfaces: 1, cpuSensors: 8, ssdSensors: 1, thermal: ThermalStatus(thermal), time: Date(), uptime: time,
            resources: ResourceSnapshot(memory: .init(totalBytes: 1000, usedBytes: 500, compressedBytes: 0, swapUsedBytes: 0, pressureLevel: pressure),
                processes: .init(cpuTop: [process], memoryTop: [process], cpuReady: true, readableCount: 1, skippedCount: 9, available: true),
                disk: .init(totalBytes: 1000, availableBytes: free, readBytesPerSecond: 1000, writeBytesPerSecond: 2000, deviceCount: 1),
                gpu: .init(utilizationPercent: 50, model: "PRIVATE_DEVICE_NAME", coreCount: 8)),
            fans: .init(rpms: [1800]), gpuTemperature: gpu, memoryProximityTemperature: nearby, gpuSensors: 8, memoryProximitySensors: 2)
    }
    static func monitorChecks() {
        let monitor = HealthAdviceMonitor()
        for time in stride(from: 0.0, through: 120.0, by: 2) { monitor.observe(sample(time, cpu: 95)) }
        precondition(monitor.probeCPUHeatDuration == 120)
        let report = monitor.report(.cpu, sample: sample(120, cpu: 95))
        precondition(report.numericInput["duration"] == 120)
        precondition(report.summary == L10n.text("CPU의 높은 온도가 이어지고 있어요"))
        monitor.observe(sample(120, cpu: 95)); precondition(monitor.probeCPUHeatDuration == 120)
        monitor.observe(sample(127, cpu: 95)); precondition(monitor.probeCPUHeatDuration == 0)
        monitor.observe(sample(129, cpu: .nan)); precondition(monitor.probeCPUHeatDuration == 0)
        monitor.observe(sample(131, cpu: 95)); precondition(monitor.probeCPUHeatDuration == 0)
        monitor.observe(sample(130, cpu: 95)); precondition(monitor.probeCPUHeatDuration == 0)
        monitor.reset(); precondition(monitor.probePointCount == 0)
        for time in stride(from: 0.0, through: 1200.0, by: 2) { monitor.observe(sample(time)) }
        precondition(monitor.probePointCount <= 151)
        for topic in AdviceTopic.allCases {
            let report = monitor.report(topic, sample: sample())
            precondition(!report.prompt.contains("PRIVATE_") && !report.prompt.contains("111") && !report.prompt.contains("account"))
            precondition(report.facts.count <= 6 && report.steps.count == 3 && report.prompt.utf8.count < 4000)
            precondition(report.numericInput.values.allSatisfy(\.isFinite))
        }
        precondition(HealthAdviceMonitor.inferenceBlocked(sample(cpu: 100)))
        precondition(HealthAdviceMonitor.inferenceBlocked(sample(gpu: 100)))
        precondition(HealthAdviceMonitor.inferenceBlocked(sample(nearby: 85)))
        precondition(HealthAdviceMonitor.inferenceBlocked(sample(pressure: 2)))
        precondition(HealthAdviceMonitor.inferenceBlocked(sample(thermal: .serious)))
        precondition(!HealthAdviceMonitor.inferenceBlocked(sample(cpu: 95, pressure: 0)))
        let missing = monitor.report(.cpu, sample: sample(cpu: nil))
        precondition(missing.facts.contains { $0.id == "cpu_temp" && $0.text.contains(L10n.text("읽기 불가")) })
        let unknownSpace = monitor.report(.disk, sample: sample(free: .nan))
        precondition(unknownSpace.numericInput["disk_free"] == nil)
        let base = monitor.report(.cpu, sample: sample())
        let valid = OnDeviceAdviceText(summary: "측정 상태", explanation: "관측된 수치에 대한 설명", supportingFacts: [base.facts[0].id])
        precondition(valid.validated(for: base) != nil)
        for bad in ["sudo kill", "CPU 999도", "https://example.com", "비활성화하세요", String(repeating: "a", count: 221)] {
            precondition(OnDeviceAdviceText(summary: "상태", explanation: bad, supportingFacts: [base.facts[0].id]).validated(for: base) == nil)
        }
        precondition(OnDeviceAdviceText(summary: "상태", explanation: "설명", supportingFacts: ["invented"]).validated(for: base) == nil)
        print("PASS health rules: continuous duration, gaps/missing/reset, bounded history, numeric-only prompt, unknown values, safety gates, output validation")
    }
    @MainActor static func wait(_ milliseconds: UInt64 = 25) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
    @MainActor static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<300 { if predicate() { return }; await wait(10) }
    }
    @MainActor static func sessionChecks() async {
        let monitor = HealthAdviceMonitor(); monitor.observe(sample())
        let base = monitor.report(.cpu, sample: sample())
        let engine = AdviceFixtureEngine(); let session = AdviceSessionController(engine: engine)
        var delivered = 0
        session.onState = { if case .explained = $0 { delivered += 1 } }
        precondition(engine.calls == 0)
        session.start(base); await wait(); precondition(engine.calls == 1 && delivered == 1)
        session.start(monitor.report(.cpu, sample: sample(cpu: 105))); await wait(); precondition(engine.calls == 1)
        engine.available = .notEnabled; session.start(base); await wait(); precondition(engine.calls == 1)
        engine.available = .ready; engine.invalid = true; session.start(base); await wait(); precondition(delivered == 1)
        engine.invalid = false; engine.delay = 80_000_000; engine.ignoresCancellation = true
        session.start(base); await wait(5); session.cancel(); await wait(); precondition(delivered == 1)
        await wait(90); precondition(!session.probeBusy)
        let timeoutEngine = AdviceFixtureEngine(); timeoutEngine.delay = 80_000_000
        let timeoutSession = AdviceSessionController(engine: timeoutEngine, timeoutNanoseconds: 5_000_000)
        var timedOut = false
        timeoutSession.onState = { if case .basic(let text) = $0 { timedOut = text == L10n.text("AI 응답을 기다리다 중단했어요. 기본 안내를 표시해요") } }
        timeoutSession.start(base); await wait(); precondition(timedOut)
        print("PASS advice sessions: explicit request only, heat/unavailable gate, invalid output fallback, cancellation, stale delivery suppression, timeout")
    }
    @MainActor static func panelChecks() async {
        let suite = "local.mac-thermal.advice-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AdviceFixtureEngine(); engine.available = .notEnabled
        let panel = PanelController(defaults: defaults, adviceEngine: engine)
        let window = DashboardWindow(controller: panel)
        let frame = window.frame
        panel.probeSetVisible(true); panel.apply(sample())
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            for topic in AdviceTopic.allCases {
                panel.probeSelectTab(topic.rawValue); panel.probeOpenAdvice()
                precondition(panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport?.topic == topic)
                precondition(panel.probeAdviceButtonFits)
                precondition(panel.probeAdviceView.probeStatus == AdviceModelAvailability.notEnabled.message)
                precondition(window.frame == frame && PanelController.surfaceSize == NSSize(width: 340, height: 420))
                panel.probeCloseAdvice(); precondition(!panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport == nil)
            }
        }
        L10n.setLanguage(.korean, defaults: defaults)
        precondition(engine.calls == 0)
        var actions: [AdviceAction] = []
        panel.adviceActionRequested = { actions.append($0) }
        panel.probeSelectTab(3); panel.probeOpenAdvice(); panel.probeAdviceView.probeAction()
        panel.probeSelectTab(0); panel.probeOpenAdvice(); panel.probeAdviceView.probeAction()
        precondition(actions == [.diskCleanup, .activityMonitor])
        panel.probeToggleSettings(); precondition(!panel.probeAdviceIsVisible)
        panel.probeToggleSettings(); panel.probeOpenAdvice(); panel.suspendAdvice()
        panel.prepareForPresentation(); precondition(!panel.probeAdviceIsVisible)
        panel.probeOpenAdvice(); window.cancelOperation(nil)
        precondition(!panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport == nil)
        panel.probeOpenAdvice(); window.orderOut(nil)
        precondition(!panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport == nil)
        engine.available = .ready
        panel.apply(sample())
        panel.probeOpenAdvice(); await eventually { panel.probeAdviceView.probeExplanation != nil }
        print("AI fixture result: calls=\(engine.calls), status=\(panel.probeAdviceView.probeStatus), report=\(panel.probeAdviceView.probeReport != nil)")
        precondition(panel.probeAdviceView.probeExplanation != nil)
        panel.apply(sample(cpu: 105)); precondition(panel.probeAdviceView.probeExplanation == nil)
        precondition(panel.probeAdviceView.probeStatus == L10n.text("고온 또는 높은 메모리 압박으로 AI 실행을 쉬고 있어요"))
        panel.probeCloseAdvice()
        precondition(window.frame == frame)
        print("PASS advice UI: five tabs/four languages, fixed frame, safe unavailable fallback, injected actions, settings/tab/dismissal cleanup, heat cancellation")
    }
    @MainActor static func main() async {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "local.mac-thermal.advice-model-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        L10n.setLanguage(.korean, defaults: defaults)
        print("STEP rules"); monitorChecks()
        print("STEP sessions"); await sessionChecks()
        print("STEP panels"); await panelChecks()
        print("All health advice tests passed with synthetic inputs and fake model only")
    }
}
