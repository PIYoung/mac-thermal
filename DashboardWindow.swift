import AppKit
import QuartzCore

/// Screen-positioned independently of the status item, which may change width.
final class DashboardWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(controller: PanelController) {
        super.init(contentRect: NSRect(origin: .zero, size: PanelController.size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Mac Thermal"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        contentViewController = controller
        setContentSize(PanelController.size)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // show(below:) constrains the visible body. The transparent shadow padding
        // may overlap the menu bar; constraining it again would add a 24 pt gap.
        frameRect
    }

    func show(below button: NSStatusBarButton) {
        guard let statusWindow = button.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) }) ?? statusWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -600, dy: -600)
        let size = PanelController.surfaceSize
        let minX = visible.minX + 8
        let maxX = max(minX, visible.maxX - size.width - 8)
        let minY = visible.minY + 8
        let menuGap: CGFloat = 2
        let maxY = max(minY, visible.maxY - size.height - menuGap)
        let menuBottom = min(anchor.minY, visible.maxY)
        let origin = NSPoint(x: min(max(anchor.midX - size.width / 2, minX), maxX),
                             y: min(max(menuBottom - size.height - menuGap, minY), maxY))
        // Set once on opening. Sampling and status item layout never reposition this window.
        let inset = PanelController.surfaceInset
        let windowOrigin = NSPoint(x: origin.x - inset, y: origin.y - inset)
        setFrame(NSRect(origin: windowOrigin, size: PanelController.size), display: false)
        contentView?.layoutSubtreeIfNeeded()
        animateOpening()
        makeKeyAndOrderFront(nil)
    }

    private func animateOpening() {
        guard let layer = contentView?.layer else { return }
        removeOpeningAnimations()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "panelOpeningFade")

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Scale the glass and its shadow together around the top center. The
        // window frame stays fixed, including during rapid close/reopen actions.
        let pivotX = PanelController.size.width / 2
        let pivotY = layer.isGeometryFlipped ? PanelController.surfaceInset : PanelController.size.height - PanelController.surfaceInset
        var start = CATransform3DMakeTranslation(pivotX, pivotY, 0)
        start = CATransform3DScale(start, 0.92, 0.92, 1)
        start = CATransform3DTranslate(start, -pivotX, -pivotY, 0)
        let spring = CASpringAnimation(keyPath: "sublayerTransform")
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 340
        spring.damping = 18
        spring.initialVelocity = 0
        spring.duration = 0.45
        layer.add(spring, forKey: "panelOpeningScale")
    }

    private func removeOpeningAnimations() {
        contentView?.layer?.removeAnimation(forKey: "panelOpeningFade")
        contentView?.layer?.removeAnimation(forKey: "panelOpeningScale")
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        removeOpeningAnimations()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            let inset = PanelController.surfaceInset
            let surface = NSRect(origin: NSPoint(x: inset, y: inset), size: PanelController.surfaceSize)
            if !surface.contains(event.locationInWindow) {
                orderOut(nil)
                return
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}
