import Foundation
import Darwin

enum SystemUptime {
    private static let secondsPerTick: Double? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return nil }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Continuous boot clock includes sleep and is independent of wall-clock changes.
    static func seconds() -> TimeInterval? {
        guard let secondsPerTick else { return nil }
        let value = Double(mach_continuous_time()) * secondsPerTick
        return value.isFinite && value >= 0 ? value : nil
    }

    static func label(_ seconds: TimeInterval?, language: AppLanguage = L10n.language) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds / 60 < Double(Int.max) else { return L10n.text("부팅 후 시간 확인 불가", language: language) }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return L10n.format("부팅 후 %d일 %d시간 %d분", language: language, days, hours, minutes) }
        if hours > 0 { return L10n.format("부팅 후 %d시간 %d분", language: language, hours, minutes) }
        if minutes > 0 { return L10n.format("부팅 후 %d분", language: language, minutes) }
        return L10n.text("부팅 후 1분 미만", language: language)
    }
}
