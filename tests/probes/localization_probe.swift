import Foundation
import AppKit

/// Standalone, read-only source checks. Persistence uses a temporary suite only.
@main
enum LocalizationProbe {
    private static var checks = 0
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }
    private static func containsHangul(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
    }
    private static func formats(_ value: String) -> [String] {
        // A format signature excludes escaped %% and respects explicit argument positions.
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?([hlLzjtq]*)([@diuoxXfFeEgGaAcCsSp%])"#)
        let ns = value as NSString
        var implicit = 0
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let type = ns.substring(with: match.range(at: 3))
            if type == "%" { return nil }
            implicit += 1
            let position = match.range(at: 1).location == NSNotFound ? String(implicit) : ns.substring(with: match.range(at: 1))
            let length = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            return "\(position):\(length)\(type)"
        }.sorted()
    }
    private static func allTables() -> [String: [String]] {
        let first = L10n.panelTranslations
        let second = L10n.systemTranslations
        for (key, value) in first where second[key] != nil {
            require(value == second[key]!, "Conflicting duplicate translation: \(key)")
        }
        let existing = first.merging(second) { left, _ in left }
        for (key, value) in L10n.cleanupTranslations where existing[key] != nil {
            require(value == existing[key]!, "Conflicting cleanup translation: \(key)")
        }
        let cleanup = existing.merging(L10n.cleanupTranslations) { left, _ in left }
        for (key, value) in L10n.codexTranslations where cleanup[key] != nil {
            require(value == cleanup[key]!, "Conflicting Codex translation: \(key)")
        }
        return cleanup.merging(L10n.codexTranslations) { left, _ in left }
    }
    private static func testPreferences() {
        let suiteName = "MacThermal.LocalizationProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        require(AppLanguage.load(defaults: defaults) == .korean, "Fresh language default must be Korean")
        defaults.set("unsupported-language", forKey: "appLanguageV1")
        require(AppLanguage.load(defaults: defaults) == .korean, "Invalid stored language must fall back to Korean")
        defaults.set(42, forKey: "appLanguageV1")
        require(AppLanguage.load(defaults: defaults) == .korean, "Invalid stored type must fall back to Korean")
        for language in AppLanguage.allCases {
            language.save(defaults: defaults)
            let reopened = UserDefaults(suiteName: suiteName)!
            require(AppLanguage.load(defaults: reopened) == language, "Language persistence failed: \(language)")
        }
        require(AppLanguage.allCases.count == 4, "Exactly four languages are required")
        require(Set(AppLanguage.allCases.map(\.nativeName)).count == 4, "Native language options must be distinct")
        for language in AppLanguage.allCases {
            require(!language.nativeName.isEmpty && !language.localeIdentifier.isEmpty, "Language metadata cannot be empty")
        }
    }
    private static func testTables(_ tables: [String: [String]]) {
        require(!tables.isEmpty, "No translations registered")
        let languages: [AppLanguage] = [.english, .japanese, .chinese]
        for (key, values) in tables.sorted(by: { $0.key < $1.key }) {
            require(values.count == 3, "Need en/ja/zh for: \(key)")
            require(L10n.text(key, language: .korean) == key, "Korean key mismatch: \(key)")
            let expectedSignature = formats(key)
            for (index, value) in values.enumerated() {
                require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty translation: \(key)")
                require(!containsHangul(value), "Untranslated Hangul in \(languages[index]): \(key)")
                if !expectedSignature.isEmpty {
                    require(formats(value) == expectedSignature, "Format arguments changed: \(key), \(languages[index]): \(formats(value)) vs \(expectedSignature)")
                }
                require(L10n.text(key, language: languages[index]) == value, "Lookup mismatch: \(key), \(languages[index])")
            }
        }
        let unknown = "Localization probe fallback"
        for language in AppLanguage.allCases {
            require(L10n.text(unknown, language: language) == unknown, "Unknown-key fallback changed")
        }
    }
    private static func testFormattingAndNotification() {
        let suiteName = "MacThermal.LanguageRefreshProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalLanguage = L10n.language
        let originalStoredValue = UserDefaults.standard.object(forKey: AppLanguage.defaultsKey) as? NSObject
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: nil) { _ in
            notifications += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            L10n.setLanguage(originalLanguage, defaults: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }
        var expectedNotifications = 0
        var previous = originalLanguage
        for language in AppLanguage.allCases {
            if previous != language { expectedNotifications += 1 }
            L10n.setLanguage(language, defaults: defaults)
            require(L10n.language == language, "Global language did not refresh")
            require(AppLanguage.load(defaults: defaults) == language, "Setter did not persist in injected suite")
            require(notifications == expectedNotifications, "Language change notification missing or duplicated")
            require(L10n.format("부팅 후 %d일 %d시간 %d분", 2, 3, 4) == L10n.format("부팅 후 %d일 %d시간 %d분", language: language, 2, 3, 4), "Current-language formatter differs from explicit formatter")
            let formatted = L10n.format("전체 %@", "12 GB")
            require(formatted.contains("12 GB") && !formatted.contains("%@"), "Object format placeholder was not substituted")
            let signed = L10n.format("조회 %d개 · 제외 %d개", 17, 2)
            require(signed.contains("17") && signed.contains("2") && !signed.contains("%d"), "Integer format placeholders were not substituted")
            previous = language
        }
        let finalStoredValue = UserDefaults.standard.object(forKey: AppLanguage.defaultsKey) as? NSObject
        require(originalStoredValue == finalStoredValue, "Probe changed actual app language preference")
    }
    private static func testLiteralCoverage(_ project: URL, tables: [String: [String]]) throws {
        let sourceNames = ["DiskCleanup.swift", "DiskCleanupView.swift", "Panel.swift", "CodexPanel.swift", "CodexMonitor.swift", "LiquidTabs.swift", "MenuBarContent.swift", "MenuBarPreferences.swift", "Uptime.swift", "LoginItem.swift", "main.swift", "Resources.swift", "DashboardWindow.swift"]
        let regex = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(\s*"((?:\\.|[^"\\])*)""#)
        let literalRegex = try NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)""#)
        var callCount = 0
        var koreanLiteralCount = 0
        for name in sourceNames {
            let source = try String(contentsOf: project.appendingPathComponent("Sources").appendingPathComponent(name), encoding: .utf8)
            let ns = source as NSString
            for match in literalRegex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let literal = ns.substring(with: match.range(at: 1))
                guard containsHangul(literal) else { continue }
                require(!literal.contains("\\("), "Unlocalized Korean interpolation in \(name): \(literal)")
                let data = Data(("\"" + literal + "\"").utf8)
                guard let key = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                    fatalError("Unsupported escaped Korean literal in \(name): \(literal)")
                }
                koreanLiteralCount += 1
                require(tables[key] != nil, "Korean literal absent from tables in \(name): \(key)")
            }
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let literal = ns.substring(with: match.range(at: 1))
                // Swift call keys are intentionally plain string literals, not interpolated text.
                if literal.contains("\\(") { fatalError("Dynamic interpolation used as localization key in \(name)") }
                let data = Data(("\"" + literal + "\"").utf8)
                guard let key = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                    fatalError("Unsupported escaped localization key in \(name): \(literal)")
                }
                callCount += 1
                require(tables[key] != nil || !containsHangul(key), "Missing translation key in \(name): \(key)")
            }
        }
        require(callCount > 20, "Expected localizable literal call sites")
        print("Literal lookup coverage: \(callCount) direct call sites, \(koreanLiteralCount) Korean UI literals")
    }
    private static func testUptime() {
        for language in AppLanguage.allCases {
            let unavailable = SystemUptime.label(nil, language: language)
            for seconds: TimeInterval? in [nil, -1, .nan, .infinity, Double.greatestFiniteMagnitude] {
                require(SystemUptime.label(seconds, language: language) == unavailable, "Invalid uptime fallback differs: \(language)")
            }
            let values: [TimeInterval] = [0, 59, 60, 3_599, 3_600, 86_399, 86_400, 90_060]
            let labels = values.map { SystemUptime.label($0, language: language) }
            require(labels[0] == labels[1], "Sub-minute boundary differs: \(language)")
            require(Set(labels.dropFirst()).count == labels.count - 1, "Uptime minute/hour/day boundaries collapsed: \(language)")
            require(labels[2].contains("1"), "One-minute uptime lost numeric value: \(language)")
            require(labels[3].contains("59"), "59-minute uptime wrong: \(language)")
            require(labels[4].contains("1"), "One-hour uptime wrong: \(language)")
            require(labels[6].contains("1"), "One-day uptime wrong: \(language)")
            require(labels[7].components(separatedBy: "1").count - 1 == 3, "Day/hour/minute uptime lost values: \(language)")
            if language != .korean {
                for label in labels + [unavailable] { require(!containsHangul(label), "Uptime left in Korean: \(language)") }
            }
            print("Uptime \(language.nativeName): \(labels[0]) / \(labels[4]) / \(labels[7])")
        }
    }
    private static func reportWidths(_ tables: [String: [String]]) {
        // Fixed frame contracts from the compact 340 pt resource body. These are layout warnings,
        // not screenshots and do not assert appearance outside the measured label region.
        let contracts: [(String, CGFloat, CGFloat)] = [
            ("CPU 애니메이션 스타일", 11, 260),
            ("메뉴바 움직임", 11, 238),
            ("움직임 강도", 11, 218),
            ("로그인 시 자동 실행", 11, 168),
            ("압축 메모리", 9, 126),
            ("스왑 사용량", 9, 126),
            ("내장 SSD", 11, 148),
            ("사용 중인 메모리", 11, 161),
            ("압박 정상", 10, 78),
            ("압박 주의", 10, 78),
            ("압박 높음", 10, 78),
            ("다음 측정부터 CPU 순위를 표시합니다", 11, 280),
            ("실제 점유 메모리", 9, 94),
            ("전체 CPU 기준", 9, 94),
            ("CPU 프로세스 TOP 3", 11, 162),
            ("메모리 프로세스 TOP 3", 11, 162),
            ("통신", 11, 53)
        ]
        let semiboldKeys: Set<String> = ["CPU 애니메이션 스타일", "메뉴바 움직임", "움직임 강도", "로그인 시 자동 실행", "압축 메모리", "스왑 사용량", "내장 SSD", "사용 중인 메모리", "압박 정상", "압박 주의", "압박 높음", "CPU 프로세스 TOP 3", "메모리 프로세스 TOP 3", "통신"]
        var warnings: [String] = []
        for (key, fontSize, width) in contracts where tables[key] != nil {
            for language in AppLanguage.allCases {
                let value = L10n.text(key, language: language)
                let measured = (value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: semiboldKeys.contains(key) ? .semibold : .regular)]).width
                if measured > width { warnings.append("\(language.nativeName): \(key), \(Int(ceil(measured))) pt > \(Int(width)) pt") }
            }
        }
        if warnings.isEmpty { print("Fixed label width probes: no measured overflows") }
        else { print("Fixed label width warnings:\n" + warnings.joined(separator: "\n")) }
    }
    static func main() throws {
        require(CommandLine.arguments.count == 2, "Usage: localization_probe <project-dir>")
        let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        testPreferences()
        let tables = allTables()
        testTables(tables)
        testFormattingAndNotification()
        try testLiteralCoverage(project, tables: tables)
        testUptime()
        reportWidths(tables)
        print("Localization checks passed: \(checks), \(tables.count) translated keys, four languages; standard defaults untouched")
    }
}
