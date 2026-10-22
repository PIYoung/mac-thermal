import AppKit

/// Original fixed-size controls. Hardware operations live in the authenticated service.
final class FanControlView: FlippedView {
    var close: (() -> Void)?
    var onBoost: ((Int) -> Void)?
    var onRestore: (() -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let rpm = NSTextField(labelWithString: "")
    private let targetTitle = NSTextField(labelWithString: "")
    private let targetValue = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(wrappingLabelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let policy = NSTextField(labelWithString: "")
    private let automatic = NSButton(title: "", target: nil, action: nil)
    private let boost = NSButton(title: "", target: nil, action: nil)
    private let back = NSButton(title: "", target: nil, action: nil)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var selectedRPM: Int?
    private var availableRange: ClosedRange<Int>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.isBordered = false; back.contentTintColor = .systemBlue
        back.font = .systemFont(ofSize: 11, weight: .medium)
        back.target = self; back.action = #selector(goBack)
        place(back, in: self, 0, 0, 57, 24)
        let reading = GlassCard()
        place(reading, in: self, 0, 31, 308, 61)
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        place(status, in: reading, 13, 8, 282, 18)
        rpm.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        rpm.lineBreakMode = .byTruncatingTail
        place(rpm, in: reading, 13, 29, 282, 25)
        let settings = GlassCard()
        place(settings, in: self, 0, 100, 308, 90)
        targetTitle.font = .systemFont(ofSize: 10, weight: .medium)
        place(targetTitle, in: settings, 13, 9, 160, 17)
        targetValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        targetValue.alignment = .right
        place(targetValue, in: settings, 177, 6, 117, 22)
        slider.target = self; slider.action = #selector(chooseRPM)
        slider.isContinuous = true
        place(slider, in: settings, 12, 33, 284, 20)
        rangeLabel.font = .systemFont(ofSize: 9)
        rangeLabel.textColor = .secondaryLabelColor
        place(rangeLabel, in: settings, 14, 60, 280, 25)
        for button in [automatic, boost] {
            button.bezelStyle = .rounded; button.controlSize = .regular
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.target = self
        }
        boost.action = #selector(startBoost); automatic.action = #selector(restore)
        place(boost, in: self, 0, 198, 192, 29)
        place(automatic, in: self, 198, 198, 110, 29)
        policy.font = .systemFont(ofSize: 9)
        policy.textColor = .secondaryLabelColor
        place(policy, in: self, 7, 232, 294, 16)
        explanation.font = .systemFont(ofSize: 9)
        explanation.textColor = .secondaryLabelColor
        place(explanation, in: self, 7, 251, 294, 26)
        update(rpms: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func update(rpms: [Double?]?, reply: FanControlWire.Reply? = nil, canStart: Bool = false) {
        back.title = "‹ CPU"
        back.setAccessibilityLabel(L10n.text("CPU 모니터로 돌아가기"))
        targetTitle.stringValue = L10n.text("목표 회전수")
        slider.setAccessibilityLabel(L10n.text("10분 냉각 강화 목표 RPM"))
        automatic.title = L10n.text("Apple 자동")
        boost.title = L10n.text("10분 냉각 강화")
        policy.stringValue = L10n.text("10분 후 자동 복귀 · 잠자기·연결 끊김에도 복귀")
        let state = reply?.state ?? .setup
        let active = state == .active || state == .starting
        if state == .active, let remaining = reply?.remaining {
            let seconds = Int(ceil(remaining))
            status.stringValue = L10n.format("냉각 강화 중 · %02d:%02d", seconds / 60, seconds % 60)
        } else {
            let key: String
            switch state {
            case .setup: key = "팬 제어 준비 중 · 회전수 읽기 전용"
            case .starting: key = "목표 회전수 적용 확인 중"
            case .connecting: key = "팬 제어 도우미 연결 중"
            case .automatic: key = "Apple 자동 제어 중"
            case .external: key = "다른 연결에서 팬을 제어하고 있어요"
            case .restoring: key = "Apple 자동 제어 복귀 확인 중"
            case .failed, .disconnected: key = "자동 제어 상태를 확인할 수 없어요"
            case .unavailable: key = "이 Mac에서 팬 제어를 확인할 수 없어요"
            case .active: key = "냉각 강화 중"
            }
            status.stringValue = L10n.text(key)
        }
        status.textColor = [.failed, .disconnected].contains(state) ? .systemOrange : .labelColor
        let actual: [Double?]? = reply.flatMap { $0.fans.isEmpty ? nil : $0.fans.map { Optional($0.actual) } } ?? rpms
        if let actual, !actual.isEmpty {
            rpm.stringValue = actual.prefix(2).map { $0.map { String(format: "%.0f", $0) } ?? "—" }.joined(separator: " / ") + " RPM"
        } else { rpm.stringValue = L10n.text(actual == nil ? "팬 정보 없음" : "팬 없음") }
        rpm.toolTip = actual?.enumerated().map { index, value in
            L10n.format("팬 %d: %@", index + 1, value.map { String(format: "%.0f RPM", $0) } ?? L10n.text("정보 없음"))
        }.joined(separator: " · ")
        availableRange = reply.flatMap { FanControlWire.range($0.fans) }
        if let range = availableRange {
            if active { selectedRPM = reply?.rpm }
            else { selectedRPM = min(range.upperBound, max(range.lowerBound, selectedRPM ?? range.upperBound)) }
            // Include the current lease target while its actual RPM settles.
            slider.minValue = Double(min(range.lowerBound, active ? (selectedRPM ?? range.lowerBound) : range.lowerBound))
            slider.maxValue = Double(max(range.upperBound, Int(slider.minValue) + 100))
            slider.doubleValue = Double(selectedRPM ?? range.upperBound)
            rangeLabel.stringValue = active ? L10n.text("목표 회전수는 냉각 강화가 끝난 뒤 다시 설정해요") : L10n.format("%d–%d RPM · 시작 시 현재 회전수 이상", range.lowerBound, range.upperBound)
        } else {
            selectedRPM = nil; slider.minValue = 0; slider.maxValue = 1; slider.doubleValue = 0
            rangeLabel.stringValue = L10n.text("도우미 연결 후 지원 범위를 확인해요")
        }
        targetValue.stringValue = selectedRPM.map { "\($0) RPM" } ?? "— RPM"
        slider.isEnabled = canStart && !active && availableRange.map { $0.lowerBound < $0.upperBound } == true
        boost.isEnabled = canStart && !active
        automatic.isEnabled = reply?.lease != nil && [.starting, .active, .restoring, .failed].contains(state)
        let key: String
        switch reply?.issue ?? .none {
        case .restoring: key = "Apple 자동 제어 복귀 확인 중"
        case .thermal: key = "열 상태가 높거나 온도를 읽지 못해 자동 제어로 복귀했어요"
        case .invalidRPM: key = "현재 회전수가 바뀌었어요. 새 범위에서 RPM을 골라 주세요"
        case .busy: key = "다른 팬 제어를 종료한 뒤 다시 확인해 주세요"
        case .recovery: key = "자동 복귀를 확인하지 못했어요. 도우미를 종료하지 말아 주세요"
        case .maintenance: key = "도우미 점검 중에는 냉각 강화를 시작하지 않아요"
        case .unsupported, .unavailable, .protocolError: key = "팬 제어 지원 여부를 확인하지 못했어요"
        case .connection: key = "도우미 연결이 끊겼어요. 자동 복귀 확인을 기다려 주세요"
        case .none:
            key = state == .setup ? "팬을 조절할 전용 관리자 도우미가 아직 연결되지 않았어요" : "낮은 RPM은 냉각이 부족할 수 있어요. 열 상태가 높으면 자동 복귀해요"
        }
        explanation.stringValue = L10n.text(key)
        boost.toolTip = explanation.stringValue; automatic.toolTip = L10n.text("냉각 강화를 끝내고 Apple 자동 제어를 확인합니다")
    }
    @objc private func chooseRPM() {
        guard let range = availableRange else { return }
        let value = min(range.upperBound, max(range.lowerBound, Int((slider.doubleValue / 100).rounded()) * 100))
        selectedRPM = value; slider.doubleValue = Double(value); targetValue.stringValue = "\(value) RPM"
    }
    @objc private func startBoost() { if boost.isEnabled, let selectedRPM { onBoost?(selectedRPM) } }
    @objc private func restore() { if automatic.isEnabled { onRestore?() } }
    private func place(_ item: NSView, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        item.frame = NSRect(x: x, y: y, width: width, height: height); parent.addSubview(item)
    }
    @objc private func goBack() { close?() }

    #if PANEL_UPDATES_PROBE
    var probeControlsDisabled: Bool { !automatic.isEnabled && !boost.isEnabled && !slider.isEnabled }
    var probeBackMatchesCleanup: Bool { !back.isBordered && back.title == "‹ CPU" && back.contentTintColor == .systemBlue && back.font == .systemFont(ofSize: 11, weight: .medium) }
    var probeTextFits: Bool { probeTextOverflows.isEmpty }
    var probeTextOverflows: String {
        var issues = [String]()
        for button in [back, automatic, boost] where (button.cell?.cellSize.width ?? 0) > button.frame.width {
            issues.append("button \(button.title): \(button.cell?.cellSize.width ?? 0) / \(button.frame.width)")
        }
        for field in [status, targetTitle, targetValue, rangeLabel, policy, explanation] {
            let size = (field.stringValue as NSString).boundingRect(with: NSSize(width: field.frame.width, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: field.font!])
            if size.height > field.frame.height { issues.append("text \(field.stringValue): \(size.height) / \(field.frame.height)") }
        }
        return issues.joined(separator: "; ")
    }
    func probeChooseRPM(_ value: Int) { slider.doubleValue = Double(value); chooseRPM() }
    func probeStart() { startBoost() }
    var probeTarget: Int? { selectedRPM }
    var probeRPM: String { rpm.stringValue }
    #endif
}
