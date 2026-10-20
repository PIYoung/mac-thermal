import AppKit
import QuartzCore

private final class DashboardGroupController: NSViewController {
    let primary: PanelController
    let companion: NSViewController?
    private let canvas = FlippedView()
    private var scroll: NSScrollView?
    private var layout: DashboardLayout?

    init(primary: PanelController, companion: NSViewController?) {
        self.primary = primary
        self.companion = companion
        super.init(nibName: nil, bundle: nil)
        addChild(primary)
        if let companion { addChild(companion) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func loadView() {
        view = FlippedView(frame: NSRect(origin: .zero, size: PanelController.size))
        view.wantsLayer = true
        canvas.wantsLayer = true
        canvas.addSubview(primary.view)
        if let companion { canvas.addSubview(companion.view) }
        view.addSubview(canvas)
    }

    func configure(_ layout: DashboardLayout) {
        _ = view
        self.layout = layout
        scroll?.documentView = nil
        scroll?.removeFromSuperview()
        scroll = nil
        canvas.removeFromSuperview()
        view.frame.size = layout.windowFrame.size
        canvas.frame = NSRect(origin: .zero, size: layout.documentSize)
        primary.view.frame = layout.primaryFrame
        companion?.view.isHidden = layout.companionFrame == nil
        if let frame = layout.companionFrame { companion?.view.frame = frame }
        if layout.scrollsVertically {
            let scroller = NSScrollView(frame: view.bounds)
            scroller.drawsBackground = false
            scroller.borderType = .noBorder
            scroller.hasVerticalScroller = true
            scroller.autohidesScrollers = true
            scroller.scrollerStyle = .overlay
            scroller.documentView = canvas
            view.addSubview(scroller)
            scroller.contentView.scroll(to: .zero)
            scroll = scroller
        } else {
            view.addSubview(canvas)
        }
        primary.prepareForPresentation()
    }

    func containsSurface(_ pointInWindow: NSPoint) -> Bool {
        guard let layout else { return true }
        if let scroller = scroll?.verticalScroller,
           !scroller.isHidden, scroller.alphaValue > 0,
           scroller.bounds.contains(scroller.convert(pointInWindow, from: nil)) { return true }
        let point = canvas.convert(pointInWindow, from: nil)
        return layout.primarySurface.contains(point) || layout.companionSurface?.contains(point) == true
    }

    #if PANEL_UPDATES_PROBE
    func probeContains(_ point: NSPoint) -> Bool {
        containsSurface(canvas.convert(point, to: nil))
    }
    func probeScroll(to point: NSPoint) {
        scroll?.contentView.scroll(to: point)
        if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
    }
    #endif
}

/// Screen-positioned independently of the status item, which may change width.
final class DashboardWindow: NSPanel {
    private let group: DashboardGroupController
    private let companionSize: NSSize
    var companionIsAvailable: (() -> Bool)?
    var prepareCompanion: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(controller: PanelController, companion: NSViewController? = nil,
         companionSize: NSSize = NSSize(width: 300, height: 420)) {
        group = DashboardGroupController(primary: controller, companion: companion)
        self.companionSize = companionSize
        super.init(contentRect: NSRect(origin: .zero, size: PanelController.size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Mac Thermal"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        contentViewController = group
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
        let hasCompanion = group.companion != nil && companionIsAvailable?() == true
        let layout = DashboardLayout.make(anchor: anchor, screen: visible,
            primary: PanelController.surfaceSize, companion: hasCompanion ? companionSize : nil)
        // Set once on opening. Sampling and status item layout never reposition the pair.
        setFrame(layout.windowFrame, display: false)
        group.configure(layout)
        if hasCompanion { prepareCompanion?() }
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
        let pivotX = frame.width / 2
        let pivotY = layer.isGeometryFlipped ? PanelController.surfaceInset : frame.height - PanelController.surfaceInset
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
            if !group.containsSurface(event.locationInWindow) {
                orderOut(nil)
                return
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }

    #if PANEL_UPDATES_PROBE
    func probeConfigure(anchor: NSRect, screen: NSRect, companion: Bool) -> DashboardLayout {
        let layout = DashboardLayout.make(anchor: anchor, screen: screen,
            primary: PanelController.surfaceSize, companion: companion ? companionSize : nil)
        setFrame(layout.windowFrame, display: false)
        group.configure(layout)
        return layout
    }
    func probeContainsCanvasPoint(_ point: NSPoint) -> Bool { group.probeContains(point) }
    func probeScroll(to point: NSPoint) { group.probeScroll(to: point) }
    #endif
}
