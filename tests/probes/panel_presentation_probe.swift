@main
struct PanelPresentationProbe {
    static func main() {
        // Missing activation notifications must not leave the menu toggle
        // permanently stuck in a pending state.
        var inactive = PanelPresentationRequest()
        let inactiveToken = inactive.begin()
        var actions: [PanelPresentationRequest.Action] = []
        for _ in 0..<12 {
            actions.append(inactive.evaluate(token: inactiveToken, hasAnchor: true,
                isActive: false, isVisible: false))
        }
        precondition(actions.contains(.show) && actions.last == .ignore)
        precondition(!inactive.pending)

        // A missing status-item window has a bounded failure path too.
        var missing = PanelPresentationRequest()
        let missingToken = missing.begin()
        var abandoned = false
        for _ in 0..<12 {
            let action = missing.evaluate(token: missingToken, hasAnchor: false,
                isActive: true, isVisible: false)
            precondition(action != .show)
            if action == .abandon { abandoned = true }
        }
        precondition(abandoned && !missing.pending)

        // The next menu click can cancel opening. An already queued retry
        // must not show the panel after that cancellation.
        var cancelled = PanelPresentationRequest()
        let cancelledToken = cancelled.begin()
        precondition(cancelled.evaluate(token: cancelledToken, hasAnchor: false,
            isActive: false, isVisible: false) == .retry)
        cancelled.cancel()
        precondition(cancelled.evaluate(token: cancelledToken, hasAnchor: true,
            isActive: true, isVisible: false) == .ignore)
        precondition(!cancelled.pending)

        // A reopened request supersedes pending asynchronous work. Stale work
        // must neither show the window nor consume the new request's budget.
        var reopened = PanelPresentationRequest(maxAttempts: 3)
        let old = reopened.begin()
        let current = reopened.begin()
        precondition(old != current)
        for _ in 0..<5 {
            precondition(reopened.evaluate(token: old, hasAnchor: true,
                isActive: true, isVisible: false) == .ignore)
        }
        precondition(reopened.pending && reopened.token == current)
        precondition(reopened.evaluate(token: current, hasAnchor: true,
            isActive: false, isVisible: false) == .retry)
        precondition(reopened.evaluate(token: current, hasAnchor: true,
            isActive: false, isVisible: false) == .retry)
        precondition(reopened.evaluate(token: current, hasAnchor: true,
            isActive: false, isVisible: false) == .show)
        precondition(!reopened.pending)

        // Activation succeeding after a delay should show immediately, and a
        // duplicate callback after successful presentation should be ignored.
        var activated = PanelPresentationRequest()
        let activationToken = activated.begin()
        precondition(activated.evaluate(token: activationToken, hasAnchor: true,
            isActive: false, isVisible: false) == .retry)
        precondition(activated.evaluate(token: activationToken, hasAnchor: true,
            isActive: true, isVisible: false) == .show)
        precondition(activated.evaluate(token: activationToken, hasAnchor: true,
            isActive: true, isVisible: false) == .ignore)

        // Another presentation path may have already opened the window.
        var visible = PanelPresentationRequest()
        let visibleToken = visible.begin()
        precondition(visible.evaluate(token: visibleToken, hasAnchor: false,
            isActive: false, isVisible: true) == .finished)
        precondition(!visible.pending)

        print("Panel presentation passed: bounded activation/anchor waits, cancellation, superseded retries, immediate activation, duplicate callbacks and already-visible completion.")
    }
}
