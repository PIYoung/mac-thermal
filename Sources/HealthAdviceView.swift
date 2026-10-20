import AppKit

/// Original compact advice surface. Generated prose never defines actions,
/// colors, links or executable commands; trusted facts and steps stay visible.
final class HealthAdviceView: FlippedView {
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let scroller = GlassScroller()
    private let document = FlippedView()
    private let retry = NSButton(title: "", target: nil, action: nil)
    private let controller: AdviceSessionController
    private var report: HealthAdviceReport?
    private var explanation: OnDeviceAdviceText?
    private var active = false
    private var scrollObserver: NSObjectProtocol?
    var requestLatest: (() -> Void)?
    var performAction: ((AdviceAction) -> Void)?
    init(frame: NSRect, engine: OnDeviceAdviceGenerating = AppleOnDeviceAdvice()) {
        controller = AdviceSessionController(engine: engine)
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 1, y: 0, width: 193, height: 21); addSubview(title)
        retry.target = self; retry.action = #selector(reanalyze)
        retry.bezelStyle = .rounded; retry.controlSize = .small; retry.font = .systemFont(ofSize: 10, weight: .medium)
        retry.frame = NSRect(x: 210, y: 0, width: 98, height: 24); addSubview(retry)
        status.font = .systemFont(ofSize: 9); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 1, y: 26, width: 306, height: 29); addSubview(status)
        scroll.frame = NSRect(x: 0, y: 60, width: 308, height: 217)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy; scroll.verticalScroller = scroller; scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true; addSubview(scroll)
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in self?.scroller.indicateScroll() }
        controller.onState = { [weak self] state in
            guard let self, self.active else { return }
            switch state {
            case .generating: self.status.stringValue = L10n.text("기기 내에서 짧은 설명을 만드는 중이에요")
            case .basic(let message): self.status.stringValue = message; self.explanation = nil; self.render()
            case .explained(let response):
                self.explanation = response; self.status.stringValue = L10n.text("온디바이스 AI 설명 · 측정 근거와 기본 안내를 함께 확인하세요"); self.render()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    func show(_ report: HealthAdviceReport) {
        controller.cancel(); self.report = report; explanation = nil; active = true
        title.stringValue = L10n.format("%@ 상태 안내", report.topic.title)
        retry.title = L10n.text("다시 분석")
        retry.setAccessibilityLabel(L10n.text("최신 측정값으로 다시 분석"))
        render(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        controller.start(report)
    }
    func suspend() {
        active = false; controller.cancel(); report = nil; explanation = nil
        document.subviews.forEach { $0.removeFromSuperview() }; status.stringValue = ""; title.stringValue = ""
    }
    func receiveSafety(_ sample: Snapshot, monitor: HealthAdviceMonitor) {
        guard active, let report, !report.inferenceBlocked, HealthAdviceMonitor.inferenceBlocked(sample) else { return }
        // A new safety constraint supersedes both the old report and its AI text.
        show(monitor.report(report.topic, sample: sample))
    }
    @objc private func reanalyze() { requestLatest?() }
    @objc private func act() { if let report { performAction?(report.action) } }
    private func label(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        let box = (value as NSString).boundingRect(with: NSSize(width: width, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: field.font!])
        field.frame.size = NSSize(width: width, height: max(size + 5, ceil(box.height) + 5))
        return field
    }
    private func render() {
        guard let report else { return }
        document.subviews.forEach { $0.removeFromSuperview() }
        let width: CGFloat = 290
        var y: CGFloat = 0
        func section(_ heading: String, _ lines: [(String, CGFloat, NSFont.Weight, NSColor)]) {
            let card = GlassCard(); var inner: CGFloat = 10
            let head = label(heading, size: 9, weight: .semibold, color: .secondaryLabelColor, width: width - 24)
            head.frame.origin = NSPoint(x: 12, y: inner); card.addSubview(head); inner += head.frame.height + 3
            for (text, size, weight, color) in lines {
                let field = label(text, size: size, weight: weight, color: color, width: width - 24)
                field.frame.origin = NSPoint(x: 12, y: inner); card.addSubview(field); inner += field.frame.height + 3
            }
            card.frame = NSRect(x: 0, y: y, width: width, height: inner + 7); document.addSubview(card); y += card.frame.height + 8
        }
        section(L10n.text("현재 상태"), [(report.summary, 12, .semibold, .labelColor), (report.explanation, 10, .regular, .secondaryLabelColor)])
        if let explanation {
            section(L10n.text("AI 설명 · 참고용"), [(explanation.summary, 11, .semibold, .labelColor), (explanation.explanation, 11, .regular, .labelColor)])
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: report.language.localeIdentifier); formatter.dateFormat = "HH:mm:ss"
        section(L10n.text("판단 근거"), [(L10n.format("측정 기준 %@", formatter.string(from: report.date)), 9, .regular, .secondaryLabelColor)] +
            report.facts.map { ("• " + $0.text, CGFloat(10), NSFont.Weight.regular, NSColor.labelColor) })
        section(L10n.text("해볼 일"), report.steps.enumerated().map { ("\($0.offset + 1). " + $0.element, CGFloat(11), NSFont.Weight.regular, NSColor.labelColor) })
        let action = NSButton(title: L10n.text(report.action == .diskCleanup ? "디스크 정리" : "활동 모니터 열기"), target: self, action: #selector(act))
        action.bezelStyle = .rounded; action.controlSize = .small; action.font = .systemFont(ofSize: 11, weight: .medium)
        action.frame = NSRect(x: 0, y: y, width: width, height: 28); document.addSubview(action); y += 36
        let privacy = label(L10n.text("숫자와 앱 안내문만 기기 내 모델에 전달해요. 원인·고장을 확정하는 진단은 아니에요"), size: 9, color: .secondaryLabelColor, width: width - 8)
        privacy.frame.origin = NSPoint(x: 4, y: y); document.addSubview(privacy); y += privacy.frame.height + 4
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.bounds.height, y))
    }
    #if HEALTH_ADVICE_PROBE
    var probeReport: HealthAdviceReport? { report }
    var probeStatus: String { status.stringValue }
    var probeExplanation: OnDeviceAdviceText? { explanation }
    func probeAction() { act() }
    #endif
}
