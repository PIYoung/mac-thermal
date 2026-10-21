import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AdviceModelAvailability: Equatable {
    case ready, requiresOS, notEnabled, preparing, unsupportedDevice, unsupportedLanguage, unavailable
    var message: String {
        L10n.text([Self.ready: "기기 내 AI · 요청할 때만 실행", .requiresOS: "macOS 26 이상에서 AI를 사용할 수 있어요", .notEnabled: "Apple Intelligence를 켜면 AI 설명을 사용할 수 있어요", .preparing: "Apple 온디바이스 모델이 아직 준비 중이에요", .unsupportedDevice: "이 Mac에서는 Apple 온디바이스 모델을 사용할 수 없어요", .unsupportedLanguage: "현재 언어는 모델에서 지원하지 않아요", .unavailable: "지금은 AI 모델을 사용할 수 없어요"][self]!)
    }
}
extension AdviceModelAvailability: Hashable {}

protocol OnDeviceAdviceGenerating: AnyObject {
    func availability(language: AppLanguage) -> AdviceModelAvailability
    func generate(_ report: HealthAdviceReport) async throws -> OnDeviceAdviceText
}

enum AdviceModelError: Error, Equatable {
    case unavailable, invalidOutput, responseFormat, modelBusy, refused, contextLimit, unsupported, generationFailed
    var message: String {
        switch self {
        case .unavailable: return L10n.text("AI 모델이 준비되지 않아 기본 안내를 표시해요")
        case .invalidOutput: return L10n.text("AI 응답을 측정 근거와 대조하지 못해 기본 안내를 표시해요")
        case .responseFormat: return L10n.text("AI 응답 형식을 읽지 못해 기본 안내를 표시해요")
        case .modelBusy: return L10n.text("AI 모델이 다른 요청을 처리 중이에요. 잠시 후 다시 분석하세요")
        case .refused: return L10n.text("기기 내 모델이 이 요청의 생성을 제한해 기본 안내를 표시해요")
        case .contextLimit: return L10n.text("AI 모델의 입력 한도를 초과해 기본 안내를 표시해요")
        case .unsupported: return L10n.text("AI 모델이 이 언어 또는 응답 형식을 지원하지 않아요")
        case .generationFailed: return L10n.text("기기 내 AI 생성 오류로 기본 안내를 표시해요")
        }
    }
    static func classify(_ error: Error) -> Self {
        if let known = error as? Self { return known }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let failure = error as? LanguageModelSession.GenerationError {
            switch failure {
            case .assetsUnavailable: return .unavailable
            case .guardrailViolation, .refusal: return .refused
            case .rateLimited, .concurrentRequests: return .modelBusy
            case .decodingFailure: return .responseFormat
            case .exceededContextWindowSize: return .contextLimit
            case .unsupportedGuide, .unsupportedLanguageOrLocale: return .unsupported
            @unknown default: return .generationFailed
            }
        }
        #endif
        return .generationFailed
    }
}

// This implementation selects ONLY SystemLanguageModel.default. There is no
// Private Cloud Compute, network client, custom provider, adapter, tool, shell,
// prewarming, app/account data access, or automatic setting/download operation.
final class AppleOnDeviceAdvice: OnDeviceAdviceGenerating {
    func availability(language: AppLanguage) -> AdviceModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale(Locale(identifier: language.localeIdentifier)) ? .ready : .unsupportedLanguage
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .preparing
            case .unavailable(.deviceNotEligible): return .unsupportedDevice
            case .unavailable: return .unavailable
            }
        }
        #endif
        return .requiresOS
    }
    #if HEALTH_ADVICE_PROBE
    static var probeFactIDs: Set<String> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return Set(AppleAdviceFactID.allCases.map(\.rawValue)) }
        #endif
        return []
    }
    #endif
    func generate(_ report: HealthAdviceReport) async throws -> OnDeviceAdviceText {
        guard availability(language: report.language) == .ready, !report.inferenceBlocked else { throw AdviceModelError.unavailable }
        try Task.checkCancellation()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = """
            Rewrite a trusted Mac resource report in the requested language. You explain observations only.
            Do not calculate, change warning severity, diagnose hardware, infer causes or identify apps.
            Never supply commands, URLs, file paths, names, instructions to change security, or new actions.
            Prefer a qualitative explanation. A number is allowed only by quoting one complete supplied evidence text
            verbatim, including its label and units, and citing that evidence ID. Do not invent or recompute numbers.
            The app displays the verified numeric facts and fixed action list separately.
            Write a summary under sixty characters and an explanation under one hundred twenty characters.
            If the cause is unknown say it cannot be determined from these measurements.
            supportingFacts must contain one to three exact evidence IDs supplied in the request.
            """
            let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [], instructions: instructions)
            let response = try await session.respond(to: report.prompt, generating: AppleAdviceOutput.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 320))
            try Task.checkCancellation()
            let result = OnDeviceAdviceText(summary: response.content.summary, explanation: response.content.explanation,
                supportingFacts: response.content.supportingFacts.map(\.rawValue))
            guard let validated = result.validated(for: report) else { throw AdviceModelError.invalidOutput }
            return validated
        }
        #endif
        throw AdviceModelError.unavailable
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct AppleAdviceOutput {
    @Guide(description: "A short observation summary; prefer words without numbers; no names, commands or recommendations")
    var summary: String
    @Guide(description: "A short explanation grounded in the supplied report, not a diagnosis; numbers only in a complete verbatim cited evidence quote; no new actions")
    var explanation: String
    @Guide(description: "One to three exact evidence IDs from the supplied report", .count(1...3))
    var supportingFacts: [AppleAdviceFactID]
}

// Constrain structured generation to app-owned IDs instead of relying on the
// model to copy arbitrary strings. Validation still requires facts in this report.
@available(macOS 26.0, *)
@Generable
private enum AppleAdviceFactID: String, CaseIterable {
    case thermal, cpu_temp, cpu_load, fan, gpu_temp, gpu_load
    case memory_used, memory_nearby, pressure, disk_free, ssd_temp
    case upload, download, duration, change
}
#endif

/// One inference at a time, bound to an explicit request and a frozen report.
/// Cancellation invalidates delivery even when the OS model takes time to stop.
@MainActor
final class AdviceSessionController {
    enum State { case basic(String), generating, retrying, explained(OnDeviceAdviceText) }
    private let engine: OnDeviceAdviceGenerating
    private var worker: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var request: UUID?
    private var busy = false
    private let timeoutNanoseconds: UInt64
    private let retryDelayNanoseconds: UInt64
    private let now: () -> Date
    var onState: ((State) -> Void)?
    init(engine: OnDeviceAdviceGenerating = AppleOnDeviceAdvice(), timeoutNanoseconds: UInt64 = 45_000_000_000,
         retryDelayNanoseconds: UInt64 = 800_000_000, now: @escaping () -> Date = Date.init) {
        self.engine = engine; self.timeoutNanoseconds = timeoutNanoseconds; self.retryDelayNanoseconds = retryDelayNanoseconds; self.now = now
    }
    deinit { worker?.cancel(); timeout?.cancel() }
    func availability(language: AppLanguage) -> AdviceModelAvailability { engine.availability(language: language) }
    func start(_ report: HealthAdviceReport) {
        cancel()
        guard abs(now().timeIntervalSince(report.date)) <= 30 else { onState?(.basic(L10n.text("기준 시각이 오래됐어요. 다시 분석하세요"))); return }
        if let reason = report.pauseReason { onState?(.basic(reason.message)); return }
        guard !busy else { onState?(.basic(L10n.text("이전 AI 요청을 정리 중이에요. 잠시 후 다시 확인하세요"))); return }
        let availability = engine.availability(language: report.language)
        guard availability == .ready else { onState?(.basic(availability.message)); return }
        let token = UUID(); request = token; busy = true
        onState?(.generating)
        worker = Task { [weak self, engine, retryDelayNanoseconds] in
            var state: State = .basic(AdviceModelError.generationFailed.message)
            for attempt in 0...1 {
                do {
                    try Task.checkCancellation()
                    let response = try await engine.generate(report)
                    try Task.checkCancellation()
                    guard let checked = response.validated(for: report) else { throw AdviceModelError.invalidOutput }
                    state = .explained(checked)
                    break
                } catch {
                    let failure = AdviceModelError.classify(error)
                    // One retry for the OS's explicit busy/rate-limited response.
                    // Never retry unsafe output, rejection, timeout or cancellation.
                    if attempt == 0, failure == .modelBusy, !Task.isCancelled,
                       let self, self.request == token {
                        self.onState?(.retrying)
                        do { try await Task.sleep(nanoseconds: retryDelayNanoseconds) } catch { break }
                        guard self.request == token, !Task.isCancelled else { break }
                        continue
                    }
                    state = .basic(failure.message)
                    break
                }
            }
            guard let self else { return }
            self.busy = false; self.worker = nil
            guard self.request == token else { return }
            self.timeout?.cancel(); self.timeout = nil; self.request = nil
            guard abs(self.now().timeIntervalSince(report.date)) <= 75, L10n.language == report.language else {
                self.onState?(.basic(L10n.text("기준 시각이 오래됐어요. 다시 분석하세요"))); return
            }
            self.onState?(state)
        }
        timeout = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            guard let self, self.request == token else { return }
            self.request = nil; self.worker?.cancel(); self.timeout = nil
            self.onState?(.basic(L10n.text("AI 응답을 기다리다 중단했어요. 기본 안내를 표시해요")))
        }
    }
    func cancel() {
        request = nil; timeout?.cancel(); timeout = nil; worker?.cancel()
        // Keep busy until the worker exits; a cancelled request may not have
        // finished releasing the OS model yet. Never queue a second inference.
    }
    #if HEALTH_ADVICE_PROBE
    var probeBusy: Bool { busy }
    #endif
}
