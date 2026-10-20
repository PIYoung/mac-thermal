import Foundation
import UserNotifications

enum CodexResetPermission { case notDetermined, denied, allowed, unavailable }
protocol CodexResetNotificationTransport: AnyObject {
    func permission(_ completion: @escaping (CodexResetPermission) -> Void)
    func requestPermission(_ completion: @escaping (CodexResetPermission) -> Void)
    func postReset(_ completion: @escaping (Bool) -> Void)
    func clearReset()
}

/// Local notifications only: no APNs registration, network, account identifiers,
/// token counts, disk history, sounds, badges or future-time notification triggers.
final class CodexNativeResetNotifications: NSObject, CodexResetNotificationTransport, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private static let identifier = "mac-thermal.codex-quota-reset"
    var mayPresent: (() -> Bool)?
    override init() { super.init(); center.delegate = self }
    func permission(_ completion: @escaping (CodexResetPermission) -> Void) {
        center.getNotificationSettings { settings in
            let state: CodexResetPermission
            switch settings.authorizationStatus {
            case .notDetermined: state = .notDetermined
            case .denied: state = .denied
            case .authorized, .provisional: state = .allowed
            @unknown default: state = .unavailable
            }
            DispatchQueue.main.async { completion(state) }
        }
    }
    func requestPermission(_ completion: @escaping (CodexResetPermission) -> Void) {
        center.requestAuthorization(options: [.alert]) { [weak self] _, error in
            guard error == nil else { DispatchQueue.main.async { completion(.unavailable) }; return }
            self?.permission(completion)
        }
    }
    func postReset(_ completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Mac Thermal"
        content.body = L10n.text("Codex 한도가 갱신됐어요")
        content.threadIdentifier = Self.identifier
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)) { error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
    func clearReset() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { [weak self] in
            completionHandler(self?.mayPresent?() == true ? [.banner, .list] : [])
        }
    }
}

/// Main-queue preference and delivery state. Permission is requested only by an
/// explicit settings action, never automatically on launch or a quota response.
final class CodexResetNotifications {
    static let enabledKey = "codexQuotaResetNotificationsV1"
    private let defaults: UserDefaults
    private let transport: CodexResetNotificationTransport
    private let now: () -> Date
    private var detector = CodexQuotaResetDetector()
    private var generation = 0
    private var latest = CodexQuotaSnapshot()
    private(set) var enabled = false
    private(set) var requesting = false
    private(set) var statusKey = "꺼짐 · 기본값"
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard, transport: CodexResetNotificationTransport, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.transport = transport; self.now = now
    }
    func start() {
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        generation += 1; let version = generation
        requesting = true; statusKey = "알림 권한 확인 중"; onChange?()
        transport.permission { [weak self] permission in
            guard let self, self.generation == version else { return }
            self.finishPermission(permission)
        }
    }
    func setEnabled(_ value: Bool) {
        guard !value || !requesting else { return }
        generation += 1; let version = generation
        detector.clear(); enabled = false
        if !value {
            requesting = false; defaults.set(false, forKey: Self.enabledKey)
            statusKey = "꺼짐 · 기본값"; transport.clearReset(); onChange?(); return
        }
        requesting = true; statusKey = "알림 권한 확인 중"; onChange?()
        transport.requestPermission { [weak self] permission in
            guard let self, self.generation == version else { return }
            self.finishPermission(permission)
        }
    }
    private func finishPermission(_ permission: CodexResetPermission) {
        requesting = false
        enabled = permission == .allowed
        defaults.set(enabled, forKey: Self.enabledKey)
        switch permission {
        case .allowed: statusKey = "켜짐 · 서버 갱신 확인 후 알림"
        case .notDetermined: statusKey = "스위치를 켜서 알림을 허용하세요"
        case .denied: statusKey = "macOS 설정에서 알림을 허용하세요"
        case .unavailable: statusKey = "알림 기능을 사용할 수 없습니다"
        }
        detector.clear()
        if enabled { _ = detector.receive(latest, at: now()) }
        onChange?()
    }
    func receive(_ snapshot: CodexQuotaSnapshot) {
        latest = snapshot
        guard enabled, !requesting, detector.receive(snapshot, at: now()) else { return }
        let version = generation
        transport.postReset { [weak self] success in
            guard let self else { return }
            guard self.generation == version, self.enabled else {
                if !self.enabled { self.transport.clearReset() }; return
            }
            if !success { self.statusKey = "리셋 알림을 전달하지 못했습니다"; self.onChange?() }
        }
    }
    func stop() { generation += 1; enabled = false; requesting = false; detector.clear(); latest = CodexQuotaSnapshot() }
}
