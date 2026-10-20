import AppKit

/// Consent and one-time device-code UI, kept outside numeric monitor snapshots.
final class CodexAccountPresenter: NSObject, NSWindowDelegate {
    private let client: CodexQuotaClient
    private var loginWindow: NSWindow?
    private var loginURL: URL?

    init(client: CodexQuotaClient) { self.client = client }

    func showAccount() {
        guard client.latest.connection != .disconnecting else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.text("ChatGPT 한도 연결")
        alert.informativeText = L10n.text("Codex의 공식 ChatGPT 로그인으로 계정 한도를 약 1분마다 조회합니다. 이 인증은 통계 전용 권한이 아니지만 Mac Thermal은 한도 조회만 요청하며 모델을 실행하지 않습니다.\n\n인증은 이 Mac의 별도 비공개 폴더에 Codex가 저장합니다. 기존 Codex 로그인은 가져오지 않습니다. 연결 해제 시 조회를 중지하고 이 앱의 인증 파일을 삭제합니다. 계정에서 접근 권한도 철회할 수 있습니다. 연결하지 않아도 로컬 기록 기능은 사용할 수 있습니다.")
        alert.addButton(withTitle: L10n.text("취소"))
        alert.addButton(withTitle: L10n.text(client.latest.isEnabled ? "연결 재시도" : "동의하고 연결"))
        if client.latest.isEnabled { alert.addButton(withTitle: L10n.text("연결 해제")) }
        let answer = alert.runModal()
        if answer == .alertSecondButtonReturn { client.connectApproved() }
        if answer == .alertThirdButtonReturn { closeLogin(); client.disconnect() }
    }

    func showUsageReview() {
        guard client.latest.connection == .connected else { showAccount(); return }
        let enabled = client.latest.usage.state != .disabled
        let alert = NSAlert()
        alert.messageText = L10n.text("계정 통계 연결")
        alert.informativeText = L10n.text("기존 ChatGPT 로그인으로 OpenAI 계정의 날짜별 토큰 통계를 조회합니다. 한도 조회보다 통계 범위가 늘어나며, 날짜와 토큰 숫자만 메모리에 표시합니다. 대화 본문과 로컬 기록은 전송하지 않습니다.\n\n약 5분마다 갱신하고, 끄면 조회와 메모리 집계를 중지합니다. 기존 한도 조회는 유지됩니다. 연결하지 않아도 모델별 로컬 기록을 볼 수 있습니다.")
        alert.addButton(withTitle: L10n.text("취소"))
        alert.addButton(withTitle: L10n.text(enabled ? "지금 새로고침" : "동의하고 조회"))
        if enabled { alert.addButton(withTitle: L10n.text("통계 연결 끄기")) }
        let answer = alert.runModal()
        if answer == .alertSecondButtonReturn {
            if enabled { client.refresh() } else { client.setUsageApproved(true) }
        }
        if answer == .alertThirdButtonReturn { client.setUsageApproved(false) }
    }

    func showSummaryReview() {
        guard client.latest.connection == .connected else { showAccount(); return }
        guard client.latest.usage.state != .disabled else { showUsageReview(); return }
        let enabled = client.latest.usage.summaryEnabled
        let alert = NSAlert()
        alert.messageText = L10n.text("계정 요약 연결")
        alert.informativeText = L10n.text("기존 OpenAI 응답에서 누적 토큰·하루 최고 토큰·현재 및 최장 연속 사용일·최장 턴 시간 5개를 추가로 표시합니다. 숫자만 이 Mac의 메모리에 보관하고 개발자 서버 전송이나 파일 저장은 하지 않습니다. 끄면 요약 숫자를 지우며 날짜별 숫자 요약은 유지됩니다. 제공되지 않는 값은 정보 없음으로 표시합니다.")
        alert.addButton(withTitle: L10n.text("취소"))
        alert.addButton(withTitle: L10n.text(enabled ? "지금 새로고침" : "동의하고 조회"))
        if enabled { alert.addButton(withTitle: L10n.text("계정 요약 끄기")) }
        let answer = alert.runModal()
        if answer == .alertSecondButtonReturn {
            if enabled { client.refresh() } else { client.setSummaryApproved(true) }
        }
        if answer == .alertThirdButtonReturn { client.setSummaryApproved(false) }
    }

    func showDeviceLogin(url: URL, code: String) {
        closeLogin()
        loginURL = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 232),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("ChatGPT 한도 연결")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: 410, height: 232))
        window.contentView = canvas
        let instruction = NSTextField(wrappingLabelWithString: L10n.text("공식 로그인 페이지에 아래 코드를 입력하세요. 비밀번호와 코드를 채팅으로 보내지 마세요."))
        instruction.font = .systemFont(ofSize: 13)
        instruction.frame = NSRect(x: 24, y: 20, width: 362, height: 54)
        canvas.addSubview(instruction)
        let codeLabel = NSTextField(labelWithString: code)
        codeLabel.font = .monospacedSystemFont(ofSize: code.count > 20 ? 14 : 20, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.isSelectable = true
        codeLabel.frame = NSRect(x: 24, y: 82, width: 362, height: 30)
        canvas.addSubview(codeLabel)
        let host = NSTextField(labelWithString: "auth.openai.com/codex/device")
        host.textColor = .secondaryLabelColor
        host.alignment = .center
        host.frame = NSRect(x: 24, y: 124, width: 362, height: 20)
        canvas.addSubview(host)
        let openButton = NSButton(title: L10n.text("공식 로그인 열기"), target: self, action: #selector(openLogin))
        openButton.bezelStyle = .rounded
        openButton.frame = NSRect(x: 178, y: 174, width: 208, height: 32)
        canvas.addSubview(openButton)
        let cancel = NSButton(title: L10n.text("취소"), target: self, action: #selector(cancelLogin))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 24, y: 174, width: 140, height: 32)
        canvas.addSubview(cancel)
        loginWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openLogin() {
        guard let loginURL else { return }
        NSWorkspace.shared.open(loginURL)
    }
    @objc private func cancelLogin() { closeLogin(); client.disconnect() }
    func windowWillClose(_ notification: Notification) {
        loginWindow = nil; loginURL = nil
        client.disconnect()
    }
    private func closeLogin() {
        loginWindow?.delegate = nil
        loginWindow?.close()
        loginWindow = nil; loginURL = nil
    }
    func receive(_ snapshot: CodexQuotaSnapshot) {
        guard snapshot.connection != .authorizing, loginWindow != nil else { return }
        closeLogin()
        if snapshot.connection == .unavailable || snapshot.connection == .needsLogin { showFailure() }
    }
    private func showFailure() {
        let alert = NSAlert()
        alert.messageText = L10n.text("계정 연결을 완료하지 못했습니다")
        alert.informativeText = L10n.text("네트워크와 Codex 앱 버전을 확인한 뒤 계정 버튼에서 다시 시도하세요. 기기 코드 로그인이 계정에서 허용되지 않으면 보안 설정을 변경하지 말고 취소하세요.")
        alert.addButton(withTitle: L10n.text("확인"))
        alert.runModal()
    }
    func showRemovalFailure() {
        let alert = NSAlert()
        alert.messageText = L10n.text("인증 파일 삭제 확인 필요")
        alert.informativeText = L10n.text("조회는 중지했습니다. 별도 인증 파일을 삭제하지 못했으므로 계정에서 접근을 철회하고 ~/Library/Application Support/Mac Thermal/Codex Account/auth.json을 직접 확인하세요. 기존 Codex 로그인 파일은 삭제하지 마세요.")
        alert.addButton(withTitle: L10n.text("확인"))
        alert.runModal()
    }
}
