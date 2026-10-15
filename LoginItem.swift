import Foundation
import ServiceManagement

/// Controls this app's login item for the current user through macOS.
/// No helper, LaunchAgent, privilege change, or fallback registration is used.
final class LoginItemManager {
    struct State {
        let enabled: Bool
        let requiresApproval: Bool
        let title: String
    }

    private enum LoginItemError: LocalizedError {
        case unsupportedSystem
        case serviceUnavailable
        case registrationUnconfirmed
        case removalUnconfirmed

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem:
                return L10n.text("로그인 자동 실행은 macOS 13 이상에서 사용할 수 있습니다.")
            case .serviceUnavailable:
                return L10n.text("이 앱의 로그인 항목을 찾을 수 없습니다. 앱 설치 위치와 코드 서명을 확인해 주세요.")
            case .registrationUnconfirmed:
                return L10n.text("로그인 자동 실행이 켜진 상태를 확인하지 못했습니다.")
            case .removalUnconfirmed:
                return L10n.text("로그인 자동 실행이 꺼진 상태를 확인하지 못했습니다.")
            }
        }
    }

    static func state() -> State {
        guard #available(macOS 13.0, *) else {
            return State(enabled: false, requiresApproval: false,
                         title: L10n.text("자동 실행: macOS 13 이상 필요"))
        }

        switch SMAppService.mainApp.status {
        case .notRegistered:
            return State(enabled: false, requiresApproval: false,
                         title: L10n.text("로그인 시 자동 실행: 꺼짐"))
        case .enabled:
            return State(enabled: true, requiresApproval: false,
                         title: L10n.text("로그인 시 자동 실행: 켜짐"))
        case .requiresApproval:
            return State(enabled: false, requiresApproval: true,
                         title: L10n.text("자동 실행: 시스템 설정에서 승인 필요"))
        case .notFound:
            return State(enabled: false, requiresApproval: false,
                         title: L10n.text("자동 실행 항목을 찾을 수 없음"))
        @unknown default:
            return State(enabled: false, requiresApproval: false,
                         title: L10n.text("자동 실행 상태 확인 불가"))
        }
    }

    static func enable() throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupportedSystem
        }

        let service = SMAppService.mainApp
        if service.status == .enabled {
            return
        }
        if service.status == .requiresApproval {
            return
        }

        try service.register()

        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            // The caller can present System Settings. state().enabled stays false.
            return
        case .notFound:
            throw LoginItemError.serviceUnavailable
        case .notRegistered:
            throw LoginItemError.registrationUnconfirmed
        @unknown default:
            throw LoginItemError.registrationUnconfirmed
        }
    }

    static func disable() throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupportedSystem
        }

        let service = SMAppService.mainApp
        if service.status == .notRegistered {
            return
        }
        try service.unregister()
        if service.status == .enabled || service.status == .requiresApproval {
            throw LoginItemError.removalUnconfirmed
        }
    }

    static func openSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
