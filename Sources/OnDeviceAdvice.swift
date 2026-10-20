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

enum AdviceModelError: Error { case unavailable, invalidOutput }

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
    func generate(_ report: HealthAdviceReport) async throws -> OnDeviceAdviceText {
        guard availability(language: report.language) == .ready, !report.inferenceBlocked else { throw AdviceModelError.unavailable }
        try Task.checkCancellation()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = """
            Rewrite a trusted Mac resource report in the requested language. You explain observations only.
            Do not calculate, change warning severity, diagnose hardware, infer causes or identify apps.
            Never supply commands, URLs, file paths, names, numbers, instructions to change security, or new actions.
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
                supportingFacts: response.content.supportingFacts)
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
    @Guide(description: "A short observation summary, no numbers, names, commands or recommendations")
    var summary: String
    @Guide(description: "A short explanation grounded in the supplied report, not a diagnosis, no numbers or new actions")
    var explanation: String
    @Guide(description: "One to three exact evidence IDs from the supplied report")
    var supportingFacts: [String]
}
#endif

/// One inference at a time, bound to an explicit request and a frozen report.
/// Cancellation invalidates delivery even when the OS model takes time to stop.
@MainActor
final class AdviceSessionController {
    enum State { case basic(String), generating, explained(OnDeviceAdviceText) }
    private let engine: OnDeviceAdviceGenerating
    private var worker: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var request: UUID?
    private var busy = false
    private let timeoutNanoseconds: UInt64
    var onState: ((State) -> Void)?
    init(engine: OnDeviceAdviceGenerating = AppleOnDeviceAdvice(), timeoutNanoseconds: UInt64 = 20_000_000_000) {
        self.engine = engine; self.timeoutNanoseconds = timeoutNanoseconds
    }
    deinit { worker?.cancel(); timeout?.cancel() }
    func availability(language: AppLanguage) -> AdviceModelAvailability { engine.availability(language: language) }
    func start(_ report: HealthAdviceReport) {
        cancel()
        guard abs(Date().timeIntervalSince(report.date)) <= 30 else { onState?(.basic(L10n.text("기준 시각이 오래됐어요. 다시 분석하세요"))); return }
        guard !report.inferenceBlocked else { onState?(.basic(L10n.text("고온 또는 높은 메모리 압박으로 AI 실행을 쉬고 있어요"))); return }
        guard !busy else { onState?(.basic(L10n.text("이전 AI 요청을 정리 중이에요. 잠시 후 다시 확인하세요"))); return }
        let availability = engine.availability(language: report.language)
        guard availability == .ready else { onState?(.basic(availability.message)); return }
        let token = UUID(); request = token; busy = true
        onState?(.generating)
        worker = Task { [weak self, engine] in
            let state: State
            do {
                let response = try await engine.generate(report)
                try Task.checkCancellation()
                guard let checked = response.validated(for: report) else { throw AdviceModelError.invalidOutput }
                state = .explained(checked)
            } catch { state = .basic(L10n.text("AI 설명을 완료하지 못해 기본 안내를 표시해요")) }
            guard let self else { return }
            self.busy = false; self.worker = nil
            guard self.request == token else { return }
            self.timeout?.cancel(); self.timeout = nil; self.worker = nil; self.request = nil
            guard abs(Date().timeIntervalSince(report.date)) <= 30, L10n.language == report.language else {
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
