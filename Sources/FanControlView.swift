import AppKit

/// Original fixed-size UI. No installer, SMC write, IPC or timer lives here.
final class FanControlView: FlippedView {
    var close: (() -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let rpm = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let policy = NSTextField(wrappingLabelWithString: "")
    private let automatic = NSButton(title: "", target: nil, action: nil)
    private let boost = NSButton(title: "", target: nil, action: nil)
    private let back = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.bezelStyle = .rounded; back.controlSize = .small
        back.font = .systemFont(ofSize: 10)
        back.target = self; back.action = #selector(goBack)
        place(back, in: self, 0, 0, 74, 24)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        place(heading, in: self, 84, 3, 224, 20)

        let reading = GlassCard()
        place(reading, in: self, 0, 33, 308, 69)
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        place(status, in: reading, 13, 10, 282, 18)
        rpm.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        rpm.lineBreakMode = .byTruncatingTail
        place(rpm, in: reading, 13, 34, 282, 25)

        let actions = GlassCard()
        place(actions, in: self, 0, 110, 308, 104)
        for button in [automatic, boost] {
            button.bezelStyle = .rounded; button.controlSize = .regular
            button.font = .systemFont(ofSize: 11, weight: .medium)
            // Real commands are deliberately not connected before security review.
            button.isEnabled = false
        }
        place(automatic, in: actions, 10, 8, 288, 28)
        place(boost, in: actions, 10, 42, 288, 28)
        policy.font = .systemFont(ofSize: 9)
        policy.textColor = .secondaryLabelColor
        place(policy, in: actions, 14, 77, 280, 20)

        explanation.font = .systemFont(ofSize: 10)
        explanation.textColor = .secondaryLabelColor
        place(explanation, in: self, 7, 225, 294, 49)
        update(rpms: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func update(rpms: [Double?]?) {
        back.title = L10n.text("돌아가기")
        heading.stringValue = L10n.text("팬 제어")
        status.stringValue = L10n.text("설정 전 · 팬 상태 읽기 전용")
        automatic.title = L10n.text("Apple 자동")
        boost.title = L10n.text("10분 냉각 강화")
        policy.stringValue = L10n.text("최대 RPM · 10분 후 자동 복귀")
        explanation.stringValue = L10n.text("실제 제어는 관리자 도우미 설치 승인 후 연결해요. 현재 제어 모드는 확인되지 않았어요.")
        if let rpms, !rpms.isEmpty {
            rpm.stringValue = rpms.prefix(2).map { value in
                value.map { String(format: "%.0f", $0) } ?? "—"
            }.joined(separator: " / ") + " RPM"
        } else { rpm.stringValue = L10n.text(rpms == nil ? "팬 정보 없음" : "팬 없음") }
        rpm.toolTip = rpms?.enumerated().map { index, value in
            L10n.format("팬 %d: %@", index + 1, value.map { String(format: "%.0f RPM", $0) } ?? L10n.text("정보 없음"))
        }.joined(separator: " · ")
        automatic.toolTip = L10n.text("관리자 도우미 연결 전에는 팬 설정을 바꾸지 않아요")
        boost.toolTip = automatic.toolTip
    }
    private func place(_ item: NSView, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        item.frame = NSRect(x: x, y: y, width: width, height: height)
        parent.addSubview(item)
    }
    @objc private func goBack() { close?() }

    #if PANEL_UPDATES_PROBE
    var probeControlsDisabled: Bool { !automatic.isEnabled && !boost.isEnabled && automatic.action == nil && boost.action == nil }
    var probeTextFits: Bool {
        [back, automatic, boost].allSatisfy { ($0.cell?.cellSize.width ?? 0) <= $0.frame.width } &&
        [heading, status, policy, explanation].allSatisfy { field in
            let size = (field.stringValue as NSString).boundingRect(with: NSSize(width: field.frame.width, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: field.font!])
            return size.height <= field.frame.height
        }
    }
    var probeRPM: String { rpm.stringValue }
    #endif
}
