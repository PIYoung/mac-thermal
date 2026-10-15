import AppKit
import QuartzCore

private final class LiquidTabButton: NSButton {
    weak var owner: LiquidTabControl?
    var selectedTab = false {
        didSet {
            state = selectedTab ? .on : .off
            setAccessibilitySelected(selectedTab)
            needsDisplay = true
        }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityValue() -> Any? { NSNumber(value: selectedTab) }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: selectedTab ? .semibold : .medium),
            .foregroundColor: selectedTab ? NSColor.white : NSColor.labelColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
    override func keyDown(with event: NSEvent) {
        if owner?.navigate(event) != true { super.keyDown(with: event) }
    }
}

/// Finite selection motion. It never changes the control or window frame.
final class LiquidTabControl: NSControl {
    private let track = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let mask = CAShapeLayer()
    private let edge = CAShapeLayer()
    private var buttons: [LiquidTabButton] = []
    private var displayObserver: NSObjectProtocol?
    private var selection = 0
    private let animationKey = "liquidSelection"

    var selectedSegment: Int {
        get { selection }
        set { select(newValue, animated: false, notify: false) }
    }

    init(labels: [String], target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(track)
        fill.mask = mask
        layer?.addSublayer(fill)
        edge.fillColor = nil
        edge.lineWidth = 0.7
        layer?.addSublayer(edge)
        for (index, title) in labels.enumerated() {
            let button = LiquidTabButton(title: title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.owner = self
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.focusRingType = .none
            button.setAccessibilityLabel(title)
            addSubview(button)
            buttons.append(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityChildren(buttons)
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateColors()
            self?.moveSelection(animated: false)
        }
        updateColors()
        select(0, animated: false, notify: false)
    }
    /// Update text in place without resetting the active tab or animating its fill.
    func updateLabels(_ labels: [String]) {
        guard labels.count == buttons.count else { return }
        for (button, title) in zip(buttons, labels) {
            button.title = title
            button.setAccessibilityLabel(title)
            button.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit {
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
    }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moveSelection(animated: false)
    }
    override func layout() {
        super.layout()
        guard !buttons.isEmpty, bounds.width > 4 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.path = pill(bounds, radius: 7)
        fill.frame = bounds
        mask.frame = bounds
        edge.frame = bounds
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
        CATransaction.commit()
        moveSelection(animated: false)
    }
    private func updateColors() {
        guard layer != nil else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor
            fill.colors = [NSColor.systemBlue.cgColor, NSColor.systemBlue.cgColor]
            fill.startPoint = CGPoint(x: 0.5, y: 1)
            fill.endPoint = CGPoint(x: 0.5, y: 0)
            edge.strokeColor = nil
            CATransaction.commit()
        }
        buttons.forEach { $0.needsDisplay = true }
    }
    private func selectionRect() -> CGRect {
        let width = bounds.width / CGFloat(max(1, buttons.count))
        return CGRect(x: CGFloat(selection) * width, y: 0, width: width, height: bounds.height)
    }
    private func select(_ index: Int, animated: Bool, notify: Bool) {
        guard buttons.indices.contains(index) else { return }
        let changed = selection != index
        selection = index
        for (position, button) in buttons.enumerated() { button.selectedTab = position == index }
        setAccessibilitySelectedChildren([buttons[index]])
        if changed || !animated { moveSelection(animated: changed && animated) }
        if changed && notify { sendAction(action, to: target) }
    }
    @objc private func pressed(_ sender: NSButton) { select(sender.tag, animated: true, notify: true) }
    override func keyDown(with event: NSEvent) {
        if !navigate(event) { super.keyDown(with: event) }
    }
    fileprivate func navigate(_ event: NSEvent) -> Bool {
        let next: Int
        switch event.keyCode {
        case 123: next = max(0, selection - 1)
        case 124: next = min(buttons.count - 1, selection + 1)
        case 115: next = 0
        case 119: next = buttons.count - 1
        default: return false
        }
        select(next, animated: true, notify: true)
        if buttons.indices.contains(next) { window?.makeFirstResponder(buttons[next]) }
        return true
    }
    private func moveSelection(animated: Bool) {
        guard bounds.width > 0, bounds.height > 4 else { return }
        let destination = selectionRect()
        let targetPath = pill(destination, radius: 7)
        let current = mask.presentation()?.path ?? mask.path ?? targetPath
        let start = current.boundingBoxOfPath
        mask.removeAnimation(forKey: animationKey)
        edge.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = targetPath
        edge.path = targetPath
        CATransaction.commit()
        guard animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(start.midX - destination.midX) > 0.5 else { return }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = [current, targetPath]
        animation.keyTimes = [0, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = 0.18
        mask.add(animation, forKey: animationKey)
        edge.add(animation, forKey: animationKey)
    }
    // Identical cubic topology permits a smooth morph from interrupted frames.
    private func pill(_ rect: CGRect, radius requested: CGFloat? = nil) -> CGPath {
        let r = min(requested ?? rect.height / 2, min(rect.width, rect.height) / 2)
        let k: CGFloat = 0.5522847498
        let x0 = rect.minX, x1 = x0 + r, x2 = rect.maxX - r, x3 = rect.maxX
        let y0 = rect.minY, y1 = y0 + r, y2 = rect.maxY - r, y3 = rect.maxY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x1, y: y0)); path.addLine(to: CGPoint(x: x2, y: y0))
        path.addCurve(to: CGPoint(x: x3, y: y1), control1: CGPoint(x: x2 + r*k, y: y0), control2: CGPoint(x: x3, y: y1 - r*k))
        path.addLine(to: CGPoint(x: x3, y: y2))
        path.addCurve(to: CGPoint(x: x2, y: y3), control1: CGPoint(x: x3, y: y2 + r*k), control2: CGPoint(x: x2 + r*k, y: y3))
        path.addLine(to: CGPoint(x: x1, y: y3))
        path.addCurve(to: CGPoint(x: x0, y: y2), control1: CGPoint(x: x1 - r*k, y: y3), control2: CGPoint(x: x0, y: y2 + r*k))
        path.addLine(to: CGPoint(x: x0, y: y1))
        path.addCurve(to: CGPoint(x: x1, y: y0), control1: CGPoint(x: x0, y: y1 - r*k), control2: CGPoint(x: x1 - r*k, y: y0))
        path.closeSubpath()
        return path
    }
}
