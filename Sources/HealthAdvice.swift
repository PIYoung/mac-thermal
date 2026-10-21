import Foundation

// Only already-collected numeric measurements enter this module. No process
// identities, paths, file candidates, records, accounts, or persistent history.
enum AdviceTopic: Int, CaseIterable {
    case cpu, gpu, memory, disk, network
    var title: String { L10n.text(["CPU", "GPU", "메모리", "SSD", "네트워크"][rawValue]) }
}

enum AdviceAction: Equatable { case activityMonitor, diskCleanup }
enum AdvicePauseReason: Equatable {
    case criticalThermal, sustainedThermal, sustainedProcessorHeat, criticalMemory
    var message: String {
        switch self {
        case .criticalThermal: return L10n.text("macOS가 위급한 열 압박을 보고해 AI를 중단했어요")
        case .sustainedThermal: return L10n.text("macOS의 심각한 열 압박이 10초 이어져 AI를 쉬고 있어요")
        case .sustainedProcessorHeat: return L10n.text("CPU 또는 GPU의 고온이 60초 지속돼 AI를 쉬고 있어요")
        case .criticalMemory: return L10n.text("macOS가 높은 메모리 압박을 보고해 AI를 중단했어요")
        }
    }
}
struct AdviceFact: Equatable {
    let id: String
    let text: String
}
struct HealthAdviceReport {
    let topic: AdviceTopic
    let date: Date
    let language: AppLanguage
    let summary: String
    let explanation: String
    let facts: [AdviceFact]
    let steps: [String]
    let action: AdviceAction
    let pauseReason: AdvicePauseReason?
    var inferenceBlocked: Bool { pauseReason != nil }
    let numericInput: [String: Double]
    var sourceIDs: Set<String> { Set(facts.map(\.id)) }
    // All strings here are trusted app text; raw/user-controlled names are never
    // interpolated. Calculations and action selection stay outside the model.
    var prompt: String {
        let numbers = (try? JSONSerialization.data(withJSONObject: numericInput, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "Language: \(language.rawValue)\nTopic: \(topic.rawValue)\nMeasurements: \(numbers)\n" +
            "Verified summary: \(summary)\nVerified explanation: \(explanation)\n" +
            "Evidence:\n" + facts.map { "\($0.id): \($0.text)" }.joined(separator: "\n") +
            "\nRewrite only these observations. Return one short summary and one short explanation. Cite one to three evidence IDs."
    }
}

/// Monotonic, bounded, in-memory observation. Gaps, invalid samples and clock
/// reversals never count as a continuously observed condition.
final class HealthAdviceMonitor {
    private enum Condition: CaseIterable { case cpuHeat, gpuHeat, memoryHeat, ssdHeat, pressure, diskLow, seriousThermal, cpuHot, gpuHot }
    private struct Point { let time: Double; let cpu: Double?; let gpu: Double? }
    private var durations: [Condition: Double] = [:]
    private var lastTime: Double?
    private var points: [Point] = []

    func observe(_ sample: Snapshot) {
        guard let time = sample.uptime, time.isFinite, time >= 0 else { reset(); return }
        let delta = lastTime.map { time - $0 }
        let continuous = delta.map { $0 >= 0 && $0 <= 6 } ?? false
        if !continuous { durations.removeAll(); points.removeAll() }
        let active: [Condition: Bool] = [
            .seriousThermal: sample.thermal.level >= 2,
            .cpuHot: sample.cpuWarning == .hot,
            .gpuHot: sample.gpuWarning == .hot,
            .cpuHeat: TemperatureWarning.cpu(sample.cpuTemperature) != .normal,
            .gpuHeat: TemperatureWarning.gpu(sample.gpuTemperature) != .normal,
            .memoryHeat: TemperatureWarning.memoryProximity(sample.memoryProximityTemperature) != .normal,
            .ssdHeat: TemperatureWarning.ssd(sample.ssdTemperature) != .normal,
            .pressure: sample.resources.memory.pressureLevel.map { (1...2).contains($0) } ?? false,
            .diskLow: freeRatio(sample).map { $0 < 0.1 } ?? false]
        for condition in Condition.allCases {
            if active[condition] == true {
                durations[condition] = durations[condition].map { $0 + max(0, delta ?? 0) } ?? 0
            } else { durations.removeValue(forKey: condition) }
        }
        lastTime = time
        points.removeAll { $0.time < time - 300 }
        let point = Point(time: time, cpu: TemperatureWarning.valid(sample.cpuTemperature), gpu: TemperatureWarning.valid(sample.gpuTemperature))
        if let last = points.last, time - last.time < 0.5 { points.removeLast() }
        points.append(point)
        if points.count > 151 { points.removeFirst(points.count - 151) }
    }
    func reset() { durations.removeAll(); points.removeAll(); lastTime = nil }
    private func freeRatio(_ sample: Snapshot) -> Double? {
        let disk = sample.resources.disk
        guard let total = disk.totalBytes, total.isFinite, total > 0,
              let free = disk.availableBytes, free.isFinite, free >= 0, free <= total else { return nil }
        return free / total
    }
    func pauseReason(for sample: Snapshot) -> AdvicePauseReason? {
        if sample.thermal.level >= 3 { return .criticalThermal }
        if sample.resources.memory.pressureLevel == 2 { return .criticalMemory }
        // Durations are monotonic observations, never wall-clock catch-up. A stale
        // sample or a reset cannot carry a previous sustained constraint forward.
        guard let time = sample.uptime, let lastTime, time.isFinite,
              time >= lastTime, time - lastTime <= 6 else { return nil }
        if sample.thermal.level >= 2, (durations[.seriousThermal] ?? 0) >= 10 { return .sustainedThermal }
        if (sample.cpuWarning == .hot && (durations[.cpuHot] ?? 0) >= 60) ||
           (sample.gpuWarning == .hot && (durations[.gpuHot] ?? 0) >= 60) { return .sustainedProcessorHeat }
        return nil
    }
    func report(_ topic: AdviceTopic, sample: Snapshot) -> HealthAdviceReport {
        var facts: [AdviceFact] = []
        var numeric: [String: Double] = [:]
        func add(_ id: String, _ text: String, _ value: Double? = nil) {
            facts.append(AdviceFact(id: id, text: text))
            if let value, value.isFinite { numeric[id] = value }
        }
        func temperature(_ id: String, _ label: String, _ raw: Double?) {
            let value = TemperatureWarning.valid(raw)
            add(id, L10n.format("%@: %@", label, value.map { String(format: "%.0f °C", $0) } ?? L10n.text("읽기 불가")), value)
        }
        func percentage(_ id: String, _ label: String, _ raw: Double?) {
            let value = raw.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            add(id, L10n.format("%@: %@", label, value.map { String(format: "%.0f%%", $0) } ?? L10n.text("읽기 불가")), value)
        }
        var summary = "현재 측정값을 확인했어요"
        var explanation = "확인된 수치만 표시하며, 원인을 단정하지 않아요"
        var steps = ["필요한 작업을 저장한 뒤 사용량이 높은 앱을 확인하세요", "통풍구가 가려져 있지 않은지 확인하세요", "작업을 줄인 뒤 수치가 내려가는지 다시 확인하세요"]
        var action = AdviceAction.activityMonitor
        var duration: Double = 0
        add("thermal", L10n.format("macOS 열 상태 · %@", sample.thermal.title), Double(sample.thermal.level))
        switch topic {
        case .cpu:
            temperature("cpu_temp", L10n.text("CPU 온도"), sample.cpuTemperature)
            percentage("cpu_load", L10n.text("CPU 사용률"), sample.cpuUsage)
            // Fan names/readings are generated solely from validated numeric SMC data.
            add("fan", sample.fans.compact)
            duration = durations[.cpuHeat] ?? 0
            if sample.cpuWarning != .normal {
                summary = duration >= 120 ? "CPU의 높은 온도가 이어지고 있어요" : "CPU 온도가 높게 측정됐어요"
                explanation = (sample.cpuUsage ?? -1) >= 60 ? "높은 CPU 부하가 함께 관측됐어요. 원인 프로세스는 활동 모니터에서 확인하세요" : "최고 코어 온도이며, 이 수치만으로 고장이나 과열을 확정할 수 없어요"
            } else if sample.cpuTemperature == nil { summary = "CPU 온도를 읽을 수 없어요" }
            else { summary = "CPU 상태를 측정값과 함께 확인하세요" }
        case .gpu:
            temperature("gpu_temp", L10n.text("GPU 온도"), sample.gpuTemperature)
            percentage("gpu_load", L10n.text("GPU 사용률"), sample.resources.gpu.utilizationPercent)
            duration = durations[.gpuHeat] ?? 0
            summary = sample.gpuWarning == .normal ? "GPU 상태를 측정값과 함께 확인하세요" : "GPU 온도가 높게 측정됐어요"
            if sample.gpuTemperature == nil { summary = "GPU 온도를 읽을 수 없어요" }
            explanation = "GPU 사용률과 온도는 다른 지표예요. 그래픽 작업의 부하를 함께 확인하세요"
        case .memory:
            let memory = sample.resources.memory
            let ratio = memory.totalBytes.flatMap { total in memory.usedBytes.flatMap { used in
                total.isFinite && total > 0 && used.isFinite && used >= 0 && used <= total ? used / total * 100 : nil } }
            percentage("memory_used", L10n.text("메모리 사용량"), ratio)
            temperature("memory_nearby", L10n.text("메모리 주변 온도"), sample.memoryProximityTemperature)
            add("pressure", L10n.format("메모리 압박: %@", memory.pressureLevel.flatMap { [0: L10n.text("압박 정상"), 1: L10n.text("압박 주의"), 2: L10n.text("압박 높음")][$0] } ?? L10n.text("정보 없음")), memory.pressureLevel.map(Double.init))
            duration = max(durations[.pressure] ?? 0, durations[.memoryHeat] ?? 0)
            summary = (memory.pressureLevel ?? 0) > 0 ? "메모리 압박을 확인하세요" : "메모리 사용률과 압박을 구분해서 보세요"
            if sample.memoryProximityWarning != .normal && (memory.pressureLevel ?? 0) == 0 { summary = "메모리 주변 온도가 높게 측정됐어요" }
            explanation = "메모리 주변 온도는 칩 내부 온도가 아니며, 사용률만으로 메모리 부족을 판단하지 않아요"
            steps = ["활동 모니터에서 메모리를 많이 쓰는 앱을 확인하세요", "필요한 작업을 저장한 뒤 사용하지 않는 앱이나 탭을 정리하세요", "앱을 정리한 뒤 메모리 압박이 회복되는지 확인하세요"]
        case .disk:
            action = .diskCleanup
            percentage("disk_free", L10n.text("사용 가능한 공간"), freeRatio(sample).map { $0 * 100 })
            temperature("ssd_temp", L10n.text("SSD 온도"), sample.ssdTemperature)
            duration = max(durations[.diskLow] ?? 0, durations[.ssdHeat] ?? 0)
            summary = (freeRatio(sample) ?? 1) < 0.1 ? "저장 공간이 적게 남아 있어요" : "SSD 공간과 온도를 함께 확인하세요"
            if sample.ssdWarning != .normal && (freeRatio(sample) ?? 0) >= 0.1 { summary = "SSD 온도가 높게 측정됐어요" }
            explanation = "정리 후보는 직접 선택하고 확인 후 휴지통으로 이동해요. 이동한 크기가 즉시 확보된 공간을 뜻하지는 않아요"
            steps = ["디스크 정리에서 검사 범위를 확인하고 검사를 시작하세요", "필요 없는 파일인지 직접 확인해 선택하세요", "최종 확인 내용과 파일 수를 확인한 뒤 휴지통으로 이동하세요"]
        case .network:
            func rate(_ key: String, _ label: String, _ raw: Double?) {
                let value = raw.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                add(key, L10n.format("%@: %@", label, speed(value)), value)
            }
            rate("upload", L10n.text("업로드"), sample.upload)
            rate("download", L10n.text("다운로드"), sample.download)
            summary = "이 Mac의 네트워크 전송량이에요"
            explanation = "전송량만으로 인터넷 품질이나 특정 앱의 원인을 판단할 수는 없어요"
            steps = ["활동 모니터의 네트워크 탭에서 전송 중인 앱을 확인하세요", "예상하지 못한 전송이면 진행 중인 다운로드나 동기화를 확인하세요", "연결 문제는 속도 숫자와 구분해서 확인하세요"]
        }
        if duration > 0 {
            add("duration", L10n.format("연속 관측: %.0f초", duration), duration)
        }
        if topic == .cpu || topic == .gpu, let first = points.first, let last = points.last, last.time - first.time >= 30 {
            let before = topic == .cpu ? first.cpu : first.gpu
            let after = topic == .cpu ? last.cpu : last.gpu
            if let before, let after { add("change", L10n.format("관측 구간 온도 변화: %+.0f °C", after - before), after - before) }
        }
        if sample.thermal.level >= 2 {
            summary = "macOS가 높은 열 압박을 보고했어요"
            explanation = "작업 부하와 통풍 상태를 확인하세요. 특정 부품의 고장으로 단정하지 않아요"
        }
        return HealthAdviceReport(topic: topic, date: sample.time, language: L10n.language,
            summary: L10n.text(summary), explanation: L10n.text(explanation), facts: facts,
            steps: steps.map(L10n.text), action: action, pauseReason: pauseReason(for: sample), numericInput: numeric)
    }
    #if HEALTH_ADVICE_PROBE
    var probePointCount: Int { points.count }
    var probeCPUHeatDuration: Double { durations[.cpuHeat] ?? 0 }
    #endif
}

struct OnDeviceAdviceText: Equatable {
    let summary: String
    let explanation: String
    let supportingFacts: [String]
    var wasFiltered = false

    func validated(for report: HealthAdviceReport) -> Self? {
        guard summary.utf8.count <= 4096, explanation.utf8.count <= 8192 else { return nil }
        let raw = summary + " " + explanation
        let forbidden = ["http", "www.", "```", "sudo", "kill ", "rm ", "chmod", "systemextensionsctl", "/users/", "disable", "uninstall", "비활성", "보안 해제", "강제 종료", "고장 확정", "恶意软件", "無効化"]
        // Executable/unsafe output fails as a whole; never salvage a fragment of
        // a command, URL, path or security instruction by sentence splitting.
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }),
              !forbidden.contains(where: raw.lowercased().contains) else { return nil }
        var seen = Set<String>()
        let evidence = Array(supportingFacts.filter { report.sourceIDs.contains($0) && seen.insert($0).inserted }.prefix(3))
        guard !evidence.isEmpty else { return nil }
        func normalized(_ text: String) -> String {
            text.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let quotes = report.facts.filter { evidence.contains($0.id) && $0.text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) }
            .map { normalized($0.text) }.sorted { $0.count > $1.count }
        func safeText(_ text: String, limit: Int) -> String {
            var accepted: [String] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { part, _, _, _ in
                guard let part else { return }
                let sentence = part.trimmingCharacters(in: .whitespacesAndNewlines)
                var remainder = normalized(sentence)
                // Numbers are accepted only inside a complete verbatim cited fact,
                // including its label and units. Matching a bare value is insufficient.
                for quote in quotes { remainder = remainder.replacingOccurrences(of: quote, with: "") }
                guard !sentence.isEmpty,
                      !remainder.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains),
                      (accepted + [sentence]).joined(separator: " ").count <= limit else { return }
                accepted.append(sentence)
            }
            return accepted.joined(separator: " ")
        }
        let cleanSummary = safeText(summary, limit: 100)
        let cleanExplanation = safeText(explanation, limit: 220)
        guard !cleanSummary.isEmpty || !cleanExplanation.isEmpty else { return nil }
        let resultSummary = cleanSummary.isEmpty ? report.summary : cleanSummary
        let resultExplanation = cleanExplanation.isEmpty ? report.explanation : cleanExplanation
        return Self(summary: resultSummary, explanation: resultExplanation, supportingFacts: evidence,
                    wasFiltered: wasFiltered || normalized(resultSummary) != normalized(summary) || normalized(resultExplanation) != normalized(explanation) || evidence != supportingFacts)
    }
}
