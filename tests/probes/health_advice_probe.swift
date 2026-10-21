import AppKit
import Foundation
import Darwin
#if canImport(FoundationModels)
import FoundationModels
#endif

// No collector, account, real model, notification or application is invoked.
enum LoginItemManager {
    struct State { let enabled: Bool; let requiresApproval: Bool; let title: String }
    static var fixtureState = State(enabled: false, requiresApproval: false, title: "Fixture")
    static func state() -> State { fixtureState }
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
    var fails = false
    var failure: AdviceModelError?
    var busyFailures = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func availability(language: AppLanguage) -> AdviceModelAvailability { available }
    private func record() { lock.lock(); count += 1; lock.unlock() }
    func generate(_ report: HealthAdviceReport) async throws -> OnDeviceAdviceText {
        record()
        if busyFailures > 0 { busyFailures -= 1; throw AdviceModelError.modelBusy }
        if let failure { throw failure }
        if fails { throw CocoaError(.featureUnsupported) }
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
                       thermal: ProcessInfo.ThermalState = .nominal, date: Date = Date()) -> Snapshot {
        let process = ResourceProcess(name: "PRIVATE_PROCESS_DO_NOT_SEND", pid: 111, cpuPercent: 90, memoryBytes: 500)
        return Snapshot(cpuTemperature: cpu, ssdTemperature: 42, cpuUsage: 70, upload: 1000, download: 2000,
            interfaces: 1, cpuSensors: 8, ssdSensors: 1, thermal: ThermalStatus(thermal), time: date, uptime: time,
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
            if #available(macOS 26.0, *) {
                precondition(report.sourceIDs.isSubset(of: AppleOnDeviceAdvice.probeFactIDs))
            }
        }
        let gate = HealthAdviceMonitor()
        precondition(gate.pauseReason(for: sample(cpu: 100, gpu: 100, nearby: 85)) == nil)
        precondition(gate.pauseReason(for: sample(pressure: 2)) == .criticalMemory)
        precondition(gate.pauseReason(for: sample(thermal: .critical)) == .criticalThermal)
        for time in stride(from: 0.0, through: 8.0, by: 2) { gate.observe(sample(time, thermal: .serious)) }
        precondition(gate.pauseReason(for: sample(8, thermal: .serious)) == nil)
        gate.observe(sample(10, thermal: .serious))
        precondition(gate.pauseReason(for: sample(10, thermal: .serious)) == .sustainedThermal)
        gate.observe(sample(12)); precondition(gate.pauseReason(for: sample(12)) == nil)
        gate.reset()
        for time in stride(from: 0.0, through: 58.0, by: 2) { gate.observe(sample(time, cpu: 101)) }
        precondition(gate.pauseReason(for: sample(58, cpu: 101)) == nil)
        gate.observe(sample(60, cpu: 101))
        precondition(gate.pauseReason(for: sample(60, cpu: 101)) == .sustainedProcessorHeat)
        precondition(gate.pauseReason(for: sample(68, cpu: 101)) == nil)
        gate.observe(sample(68, cpu: 101)); precondition(gate.pauseReason(for: sample(68, cpu: 101)) == nil)
        gate.reset()
        for time in stride(from: 0.0, through: 60.0, by: 2) { gate.observe(sample(time, gpu: 100)) }
        precondition(gate.pauseReason(for: sample(60, gpu: 100)) == .sustainedProcessorHeat)
        gate.observe(sample(62, gpu: .nan)); precondition(gate.pauseReason(for: sample(62, gpu: .nan)) == nil)
        gate.reset()
        for time in stride(from: 0.0, through: 120.0, by: 2) { gate.observe(sample(time, nearby: 90)) }
        precondition(gate.pauseReason(for: sample(120, nearby: 90)) == nil)
        gate.observe(sample(119, cpu: 101)); precondition(gate.pauseReason(for: sample(119, cpu: 101)) == nil)
        let missing = monitor.report(.cpu, sample: sample(cpu: nil))
        precondition(missing.facts.contains { $0.id == "cpu_temp" && $0.text.contains(L10n.text("읽기 불가")) })
        let unknownSpace = monitor.report(.disk, sample: sample(free: .nan))
        precondition(unknownSpace.numericInput["disk_free"] == nil)
        let base = monitor.report(.cpu, sample: sample())
        let valid = OnDeviceAdviceText(summary: "측정 상태", explanation: "관측된 수치에 대한 설명", supportingFacts: [base.facts[0].id])
        precondition(valid.validated(for: base) != nil)
        for bad in ["sudo kill", "https://example.com", "비활성화하세요"] {
            precondition(OnDeviceAdviceText(summary: "상태", explanation: bad, supportingFacts: [base.facts[0].id]).validated(for: base) == nil)
        }
        precondition(OnDeviceAdviceText(summary: "상태", explanation: "설명", supportingFacts: ["invented"]).validated(for: base) == nil)
        let numeric = base.facts.first { $0.id == "cpu_temp" }!
        let quote = OnDeviceAdviceText(summary: "측정 상태", explanation: numeric.text + "입니다.", supportingFacts: ["cpu_temp"])
        precondition(quote.validated(for: base)?.explanation == quote.explanation)
        let partial = OnDeviceAdviceText(summary: "측정 상태", explanation: "CPU 999도입니다. 이 수치만으로 원인을 확정할 수 없어요.", supportingFacts: ["cpu_temp", "invented", "cpu_temp"])
        let filtered = partial.validated(for: base)!
        precondition(filtered.wasFiltered && !filtered.explanation.contains("999") && filtered.explanation.contains("원인"))
        precondition(filtered.supportingFacts == ["cpu_temp"])
        precondition(filtered.validated(for: base)?.wasFiltered == true)
        precondition(OnDeviceAdviceText(summary: "999", explanation: "CPU 999도입니다.", supportingFacts: ["cpu_temp"]).validated(for: base) == nil)
        let wrongUnit = OnDeviceAdviceText(summary: "측정 상태", explanation: "CPU 온도: 65%입니다.", supportingFacts: ["cpu_temp"])
        precondition(wrongUnit.validated(for: base)?.explanation == base.explanation)
        let wrongCitation = OnDeviceAdviceText(summary: "측정 상태", explanation: numeric.text, supportingFacts: ["thermal"])
        precondition(wrongCitation.validated(for: base)?.explanation == base.explanation)
        let unsafe = OnDeviceAdviceText(summary: "정상 문장", explanation: "현재 상태를 확인하세요. sudo kill 123", supportingFacts: ["cpu_temp"])
        precondition(unsafe.validated(for: base) == nil)
        precondition(OnDeviceAdviceText(summary: "측정 상태", explanation: String(repeating: "a", count: 221), supportingFacts: ["cpu_temp"]).validated(for: base)?.explanation == base.explanation)
        let suite = "local.mac-thermal.advice-filter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let report = monitor.report(.cpu, sample: sample())
            let fact = report.facts.first { $0.id == "cpu_temp" }!
            let sentence = L10n.text("확인된 수치만 표시하며, 원인을 단정하지 않아요")
            let raw = OnDeviceAdviceText(summary: report.summary, explanation: fact.text + ". " + sentence, supportingFacts: [fact.id])
            precondition(raw.validated(for: report)?.explanation.contains(fact.text) == true)
            let mixed = OnDeviceAdviceText(summary: report.summary, explanation: "9999999. " + sentence, supportingFacts: [fact.id])
            precondition(mixed.validated(for: report)?.wasFiltered == true)
            precondition(mixed.validated(for: report)?.explanation.contains("9999999") == false)
            let messages = [AdvicePauseReason.criticalThermal.message, AdvicePauseReason.sustainedThermal.message,
                            AdvicePauseReason.sustainedProcessorHeat.message, AdvicePauseReason.criticalMemory.message,
                            AdviceModelError.unavailable.message, AdviceModelError.invalidOutput.message,
                            AdviceModelError.responseFormat.message, AdviceModelError.modelBusy.message,
                            AdviceModelError.refused.message, AdviceModelError.contextLimit.message,
                            AdviceModelError.unsupported.message, AdviceModelError.generationFailed.message,
                            L10n.text("AI 모델이 사용 중이라 한 번 다시 시도해요"), L10n.text("응답 일부를 제외하고 검증된 설명을 표시해요")]
            for message in messages {
                let box = (message as NSString).boundingRect(with: NSSize(width: 306, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 9)])
                precondition(ceil(box.height) <= 29, "Advice status overflows: \(language) \(message)")
            }
        }
        L10n.setLanguage(.korean, defaults: defaults)
        print("PASS health rules: transient/duration/critical gates, gaps/recovery, complete cited numeric quotes, partial filtering, unsafe-output rejection and four-language status bounds")
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
        session.start(monitor.report(.cpu, sample: sample(thermal: .critical))); await wait(); precondition(engine.calls == 1)
        for availability: AdviceModelAvailability in [.requiresOS, .notEnabled, .preparing, .unsupportedDevice, .unsupportedLanguage, .unavailable] {
            engine.available = availability
            var message: String?
            session.onState = { if case .basic(let text) = $0 { message = text } }
            session.start(base); await wait()
            precondition(engine.calls == 1 && message == availability.message)
        }
        session.onState = { if case .explained = $0 { delivered += 1 } }
        engine.available = .ready; engine.invalid = true; session.start(base); await wait(); precondition(delivered == 1)
        engine.invalid = false; engine.delay = 80_000_000; engine.ignoresCancellation = true
        session.start(base); await wait(5); session.cancel(); await wait(); precondition(delivered == 1)
        await wait(90); precondition(!session.probeBusy)
        engine.fails = true
        var failureMessage: String?
        session.onState = { if case .basic(let text) = $0 { failureMessage = text } }
        session.start(base); await eventually { failureMessage != nil }
        precondition(failureMessage == AdviceModelError.generationFailed.message)
        engine.fails = false
        let timeoutEngine = AdviceFixtureEngine(); timeoutEngine.delay = 80_000_000
        let timeoutSession = AdviceSessionController(engine: timeoutEngine, timeoutNanoseconds: 5_000_000)
        var timedOut = false
        timeoutSession.onState = { if case .basic(let text) = $0 { timedOut = text == L10n.text("AI 응답을 기다리다 중단했어요. 기본 안내를 표시해요") } }
        timeoutSession.start(base); await wait(); precondition(timedOut)
        precondition(timeoutEngine.calls == 1)
        for failure: AdviceModelError in [.unavailable, .invalidOutput, .responseFormat, .refused, .contextLimit, .unsupported, .generationFailed] {
            let failing = AdviceFixtureEngine(); failing.failure = failure
            let controller = AdviceSessionController(engine: failing, retryDelayNanoseconds: 1_000_000)
            var text: String?
            controller.onState = { if case .basic(let message) = $0 { text = message } }
            controller.start(base); await eventually { text != nil }
            precondition(text == failure.message && failing.calls == 1)
        }
        let busy = AdviceFixtureEngine(); busy.busyFailures = 1
        let retrying = AdviceSessionController(engine: busy, retryDelayNanoseconds: 1_000_000)
        var retried = 0, finished = false
        retrying.onState = { if case .retrying = $0 { retried += 1 }; if case .explained = $0 { finished = true } }
        retrying.start(base); await eventually { finished }
        precondition(finished && busy.calls == 2 && retried == 1)
        let alwaysBusy = AdviceFixtureEngine(); alwaysBusy.busyFailures = 3
        let limited = AdviceSessionController(engine: alwaysBusy, retryDelayNanoseconds: 1_000_000)
        var limitedMessage: String?
        limited.onState = { if case .basic(let message) = $0 { limitedMessage = message } }
        limited.start(base); await eventually { limitedMessage != nil }
        precondition(limitedMessage == AdviceModelError.modelBusy.message && alwaysBusy.calls == 2)
        let delayed = AdviceFixtureEngine(); delayed.busyFailures = 1
        let cancelled = AdviceSessionController(engine: delayed, retryDelayNanoseconds: 100_000_000)
        var waitingRetry = false, unwantedDelivery = false
        cancelled.onState = { if case .retrying = $0 { waitingRetry = true }; if case .explained = $0 { unwantedDelivery = true } }
        cancelled.start(base); await eventually { waitingRetry }; cancelled.cancel(); await wait(150)
        precondition(delayed.calls == 1 && !unwantedDelivery && !cancelled.probeBusy)
        var clock = Date()
        let dated = monitor.report(.cpu, sample: sample(date: clock))
        let slow = AdviceFixtureEngine(); slow.delay = 10_000_000
        let fresh = AdviceSessionController(engine: slow, now: { clock })
        var accepted = false
        fresh.onState = { if case .explained = $0 { accepted = true } }
        fresh.start(dated); clock.addTimeInterval(40); await eventually { accepted }
        precondition(accepted, "A result within the extended request deadline must remain usable")
        var oldMessage: String?
        fresh.onState = { if case .basic(let message) = $0 { oldMessage = message } }
        fresh.start(dated); precondition(oldMessage == L10n.text("기준 시각이 오래됐어요. 다시 분석하세요"))
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "Synthetic fixture only")
            for (error, expected) in [
                (LanguageModelSession.GenerationError.concurrentRequests(context), AdviceModelError.modelBusy),
                (.rateLimited(context), .modelBusy), (.assetsUnavailable(context), .unavailable),
                (.decodingFailure(context), .responseFormat), (.guardrailViolation(context), .refused),
                (.exceededContextWindowSize(context), .contextLimit), (.unsupportedLanguageOrLocale(context), .unsupported)
            ] { precondition(AdviceModelError.classify(error) == expected) }
        }
        #endif
        print("PASS advice sessions: reason-specific errors, one busy retry, bounded retry exhaustion/cancellation, extended freshness, explicit requests, timeout and stale delivery suppression")
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
                precondition(panel.probeAdviceEntryIsProminent && panel.probeAdviceHeaderFits)
                precondition(panel.probeAdviceView.probeStatus == AdviceModelAvailability.notEnabled.message)
                precondition(window.frame == frame && PanelController.surfaceSize == NSSize(width: 340, height: 420))
                panel.probeCloseAdvice(); precondition(!panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport == nil)
            }
        }
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            for availability: AdviceModelAvailability in [.requiresOS, .notEnabled, .preparing, .unsupportedDevice, .unsupportedLanguage, .unavailable] {
                engine.available = availability
                for topic in AdviceTopic.allCases {
                    panel.probeSelectTab(topic.rawValue); panel.probeOpenAdvice()
                    precondition(panel.probeAdviceView.probeStatus == availability.message)
                    for key in ["현재 상태", "판단 근거", "해볼 일"] {
                        precondition(panel.probeAdviceDocumentText.contains(L10n.text(key)))
                    }
                    precondition(panel.probeAdviceView.probeExplanation == nil)
                    panel.probeCloseAdvice()
                    precondition(panel.probeAdviceEntryIsProminent && panel.probeAdviceButtonFits)
                }
            }
            for (state, expected) in [
                (LoginItemManager.State(enabled: false, requiresApproval: false, title: "Not registered fixture"), "꺼짐"),
                (LoginItemManager.State(enabled: false, requiresApproval: true, title: "Approval required fixture"), "승인 필요"),
                (LoginItemManager.State(enabled: true, requiresApproval: false, title: "Enabled fixture"), "켜짐")
            ] {
                LoginItemManager.fixtureState = state; panel.updateLoginState()
                precondition(panel.probeLoginLabel == L10n.text(expected) && panel.probeAdviceEntryIsProminent)
            }
        }
        engine.available = .notEnabled
        L10n.setLanguage(.korean, defaults: defaults)
        precondition(engine.calls == 0)
        var actions: [AdviceAction] = []
        panel.adviceActionRequested = { actions.append($0) }
        panel.probeSelectTab(3); panel.probeOpenAdvice(); panel.probeAdviceView.probeAction()
        panel.probeSelectTab(0); panel.probeOpenAdvice(); panel.probeAdviceView.probeAction()
        precondition(actions == [.diskCleanup, .activityMonitor])
        panel.probeToggleSettings(); precondition(!panel.probeAdviceIsVisible)
        precondition(!panel.probeAdviceEntryIsProminent)
        panel.probeToggleSettings(); panel.probeOpenAdvice(); panel.suspendAdvice()
        panel.prepareForPresentation(); precondition(!panel.probeAdviceIsVisible)
        panel.probeOpenAdvice(); window.cancelOperation(nil)
        precondition(!panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport == nil)
        panel.probeOpenAdvice(); window.orderOut(nil)
        precondition(!panel.probeAdviceIsVisible && panel.probeAdviceView.probeReport == nil)
        engine.available = .ready
        panel.apply(sample())
        panel.probeOpenAdvice(); precondition(!panel.probeAdviceView.probeRetryEnabled)
        await eventually { panel.probeAdviceView.probeExplanation != nil }
        precondition(panel.probeAdviceView.probeRetryEnabled)
        print("AI fixture result: calls=\(engine.calls), status=\(panel.probeAdviceView.probeStatus), report=\(panel.probeAdviceView.probeReport != nil)")
        precondition(panel.probeAdviceView.probeExplanation != nil)
        panel.apply(sample(2, cpu: 105)); precondition(panel.probeAdviceView.probeExplanation != nil)
        panel.apply(sample(4, thermal: .critical)); precondition(panel.probeAdviceView.probeExplanation == nil)
        precondition(panel.probeAdviceView.probeStatus == AdvicePauseReason.criticalThermal.message)
        panel.probeCloseAdvice()
        precondition(window.frame == frame)
        print("PASS advice UI: prominent header button, five tabs/four languages, six unavailable-model states with basic guidance, login-approval fixture states, fixed frame, injected actions, settings/tab/dismissal cleanup, heat cancellation")
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
