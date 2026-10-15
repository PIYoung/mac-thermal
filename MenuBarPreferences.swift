import Foundation

enum MenuBarAnimationStyle: Int, CaseIterable {
    case rhythm = 0
    case orbit = 1

    var title: String { L10n.text(self == .rhythm ? "리듬 막대" : "순환 점") }
}

struct MenuBarPreferences: Equatable {
    var style: MenuBarAnimationStyle = .rhythm
    var motionEnabled = true
    var intensity = 1.2

    private static let styleKey = "menuBarAnimationStyleV2"
    private static let motionKey = "menuBarMotionEnabledV2"
    private static let intensityKey = "menuBarMotionIntensityV2"

    static func load(defaults: UserDefaults = .standard) -> Self {
        let storedIntensity = defaults.object(forKey: intensityKey) as? Double ?? 1.2
        return Self(
            style: MenuBarAnimationStyle(rawValue: defaults.integer(forKey: styleKey)) ?? .rhythm,
            motionEnabled: defaults.object(forKey: motionKey) as? Bool ?? true,
            intensity: storedIntensity.isFinite ? max(0.75, min(1.5, storedIntensity)) : 1.2)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: Self.styleKey)
        defaults.set(motionEnabled, forKey: Self.motionKey)
        defaults.set(intensity.isFinite ? max(0.75, min(1.5, intensity)) : 1.2, forKey: Self.intensityKey)
    }
}
