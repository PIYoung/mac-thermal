/// Bounded presentation requests independent of AppKit activation callbacks.
/// A cancelled or superseded request cannot reopen the panel from a queued retry.
struct PanelPresentationRequest {
    enum Action: Equatable {
        case ignore
        case retry
        case show
        case finished
        case abandon
    }

    private(set) var token: UInt?
    var pending: Bool { token != nil }

    /// An ordered window may still be hidden by AppKit or another Space.
    /// Reopening must bring it forward rather than treat it as an open toggle.
    static func isPresented(isOrdered: Bool, isExposed: Bool, appHidden: Bool) -> Bool {
        isOrdered && isExposed && !appHidden
    }

    private let maxAttempts: Int
    private var generation: UInt = 0
    private var attempts = 0

    init(maxAttempts: Int = 10) {
        self.maxAttempts = max(1, maxAttempts)
    }

    @discardableResult
    mutating func begin() -> UInt {
        generation &+= 1
        token = generation
        attempts = 0
        return generation
    }

    mutating func cancel() {
        token = nil
        attempts = 0
    }

    mutating func evaluate(token requestedToken: UInt, hasAnchor: Bool,
                           isActive: Bool, isVisible: Bool) -> Action {
        guard token == requestedToken else { return .ignore }
        if isVisible {
            cancel()
            return .finished
        }
        attempts += 1
        if hasAnchor && (isActive || attempts >= maxAttempts) {
            // App activation can finish without a matching callback. An
            // anchored final attempt still orders the panel front explicitly.
            cancel()
            return .show
        }
        if attempts >= maxAttempts {
            cancel()
            return .abandon
        }
        return .retry
    }
}
