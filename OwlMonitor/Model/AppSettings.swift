import Foundation
import AppKit

/// App-wide settings (the gear at the bottom of the sidebar). Persisted under Application Support.
struct AppSettings: Codable, Sendable, Equatable {
    /// App display name of the browser used by "Open" (e.g. "Google Chrome"); nil = system default.
    var browser: String?
    /// App display name of the editor used by "Code" (e.g. "Cursor"); nil = VS Code / first found.
    var editor: String?
    /// Claude model used for Diagnose, the Resource Advisor, and pressure auto-analysis.
    var analysisModel: String
    /// Auto-close orphaned dev processes when the machine is under pressure.
    var autoCloseOrphans: Bool
    /// Heap (GB) applied to new projects whose framework has no specific default.
    var defaultMemoryGB: Int
    /// Which activity bars to show on the dashboard (ids from `allBars`).
    var bars: [String]
    /// Show the live metric timeline charts (Activity timeline accordion + per-project charts).
    var showCharts: Bool
    /// UI appearance: "system" (follow macOS), "light", or "dark".
    var theme: String
    /// Terminal/log appearance: "app" (follow the app theme), "dark", or "light".
    var terminalTheme: String
    /// UI language: "system" (follow macOS) or a code ("en", "es", "fr"). Applied via AppleLanguages;
    /// takes effect on the next launch.
    var language: String

    // Notifications — master switch + a toggle per category (see NotificationCategory).
    var notificationsEnabled: Bool
    var notifyFailures: Bool
    var notifyRecovery: Bool
    var notifyBuilds: Bool
    var notifyPressure: Bool
    /// Optional Slack/Discord/incoming-webhook URL. When set, every notification that passes the
    /// category policy is also POSTed here. Empty = off.
    var notifyWebhookURL: String

    init(browser: String? = nil,
         editor: String? = nil,
         analysisModel: String = AppSettings.defaultModel,
         autoCloseOrphans: Bool = true,
         defaultMemoryGB: Int = 4,
         bars: [String] = AppSettings.defaultBars,
         showCharts: Bool = true,
         theme: String = "system",
         terminalTheme: String = "dark",
         language: String = "system",
         notificationsEnabled: Bool = true,
         notifyFailures: Bool = true,
         notifyRecovery: Bool = true,
         notifyBuilds: Bool = true,
         notifyPressure: Bool = true,
         notifyWebhookURL: String = "") {
        self.browser = browser
        self.editor = editor
        self.analysisModel = analysisModel
        self.autoCloseOrphans = autoCloseOrphans
        self.defaultMemoryGB = defaultMemoryGB
        self.bars = bars
        self.showCharts = showCharts
        self.theme = theme
        self.terminalTheme = terminalTheme
        self.language = language
        self.notificationsEnabled = notificationsEnabled
        self.notifyFailures = notifyFailures
        self.notifyRecovery = notifyRecovery
        self.notifyBuilds = notifyBuilds
        self.notifyPressure = notifyPressure
        self.notifyWebhookURL = notifyWebhookURL
    }

    // Tolerant decode so older settings.json (missing keys) still loads.
    enum CodingKeys: String, CodingKey {
        case browser, editor, analysisModel, autoCloseOrphans, defaultMemoryGB, bars, showCharts, theme, terminalTheme, language
        case notificationsEnabled, notifyFailures, notifyRecovery, notifyBuilds, notifyPressure, notifyWebhookURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        editor = try c.decodeIfPresent(String.self, forKey: .editor)
        analysisModel = AppSettings.currentModel(for: try c.decodeIfPresent(String.self, forKey: .analysisModel))
        autoCloseOrphans = try c.decodeIfPresent(Bool.self, forKey: .autoCloseOrphans) ?? true
        defaultMemoryGB = try c.decodeIfPresent(Int.self, forKey: .defaultMemoryGB) ?? 4
        bars = try c.decodeIfPresent([String].self, forKey: .bars) ?? AppSettings.defaultBars
        showCharts = try c.decodeIfPresent(Bool.self, forKey: .showCharts) ?? true
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        terminalTheme = try c.decodeIfPresent(String.self, forKey: .terminalTheme) ?? "dark"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "system"
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        notifyFailures = try c.decodeIfPresent(Bool.self, forKey: .notifyFailures) ?? true
        notifyRecovery = try c.decodeIfPresent(Bool.self, forKey: .notifyRecovery) ?? true
        notifyBuilds = try c.decodeIfPresent(Bool.self, forKey: .notifyBuilds) ?? true
        notifyPressure = try c.decodeIfPresent(Bool.self, forKey: .notifyPressure) ?? true
        notifyWebhookURL = try c.decodeIfPresent(String.self, forKey: .notifyWebhookURL) ?? ""
    }

    static let defaultModel = "claude-haiku-4-5-20251001"

    /// Appearance options for the theme picker.
    struct ThemeOption: Identifiable, Sendable { let id: String; let label: String; let icon: String }
    static let themes: [ThemeOption] = [
        .init(id: "system", label: "System", icon: "circle.lefthalf.filled"),
        .init(id: "light", label: "Light", icon: "sun.max.fill"),
        .init(id: "dark", label: "Dark", icon: "moon.fill"),
    ]
    /// Terminal/log appearance options ("app" follows the app theme).
    static let terminalThemes: [ThemeOption] = [
        .init(id: "app", label: "Match app", icon: "circle.lefthalf.filled"),
        .init(id: "light", label: "Light", icon: "sun.max.fill"),
        .init(id: "dark", label: "Dark", icon: "moon.fill"),
    ]

    /// Apply a theme to the whole app (all windows, modals and the menu-bar panel).
    /// Uses `NSApplication.shared` (never nil) — `NSApp` is still nil during SwiftUI `App.init`.
    @MainActor static func applyAppearance(_ theme: String) {
        let appearance: NSAppearance? = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark":  NSAppearance(named: .darkAqua)
        default:      nil   // follow the system setting
        }
        NSApplication.shared.appearance = appearance
    }

    /// Apply the saved UI language by overriding the app's `AppleLanguages`. "system" clears the
    /// override (follow macOS). The bundle resolves localizations at startup, so a change takes full
    /// effect on the next launch — call this at launch (to mirror settings.json → defaults) and on
    /// every change (so the next launch honours it).
    static func applyLanguage(_ code: String) {
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    /// Languages offered in the picker. Endonyms (English/Español/Français) aren't translated;
    /// "System" is (via `LocalizedStringKey`).
    static let languages: [(id: String, label: String)] = [
        ("system", "System"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
    ]

    /// Models offered for analysis (newest Claude family).
    struct ModelOption: Identifiable, Sendable { let id: String; let label: String }
    static let models: [ModelOption] = [
        .init(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5 — fast (default)"),
        .init(id: "claude-sonnet-5", label: "Sonnet 5 — balanced"),
        .init(id: "claude-opus-5-5", label: "Opus 5.5 — deep"),
    ]

    /// A saved model ID mapped onto today's list. IDs retire as new models ship, and a retired one
    /// would leave the picker blank and make every `claude --model` call fail — so a stale ID moves
    /// to the newest model of the SAME tier (an old Sonnet becomes the current Sonnet), and anything
    /// unrecognisable falls back to the default.
    static func currentModel(for saved: String?) -> String {
        guard let saved, !saved.isEmpty else { return defaultModel }
        if models.contains(where: { $0.id == saved }) { return saved }
        for tier in ["haiku", "sonnet", "opus"] where saved.contains(tier) {
            if let match = models.first(where: { $0.id.contains(tier) }) { return match.id }
        }
        return defaultModel
    }

    /// Activity bars: CPU/Memory/Swap/Temperature on by default; the rest are optional.
    static let defaultBars = ["cpu", "memory", "swap", "temp"]
    struct Bar: Identifiable, Sendable { let id: String; let label: String }
    static let allBars: [Bar] = [
        .init(id: "cpu", label: "CPU"),
        .init(id: "memory", label: "Memory"),
        .init(id: "swap", label: "Swap"),
        .init(id: "temp", label: "Temperature"),
        .init(id: "load", label: "Load average"),
        .init(id: "devcpu", label: "Dev server CPU"),
        .init(id: "devmem", label: "Dev server memory"),
    ]
}

/// Loads and saves `AppSettings` as versioned JSON under Application Support, on top of the
/// corruption-safe `JSONFileStore` (an unreadable file is backed up, never silently reset away).
@MainActor
final class SettingsStore {
    private let store = JSONFileStore<AppSettings>(filename: "settings.json", version: 1)

    /// Load the persisted settings. `corruptBackup` is non-nil only when the file existed but was
    /// unreadable — settings were reset to defaults and the bad file preserved at that path, so the
    /// user can be told instead of silently losing every preference.
    func load() -> (settings: AppSettings, corruptBackup: URL?) {
        switch store.load() {
        case .missing:             return (AppSettings(), nil)
        case .loaded(let s):       return (s, nil)
        case .corrupt(let backup): return (AppSettings(), backup)
        }
    }

    func save(_ settings: AppSettings) { store.save(settings) }
}

/// Browsers installed on this Mac (apps that can open http), by display name.
enum BrowserList {
    @MainActor static func installed() -> [String] {
        guard let url = URL(string: "https://example.com") else { return [] }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var names: [String] = []
        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: "")
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }
}

/// Code editors / IDEs installed on this Mac. Detected dynamically as the apps that register to
/// open a *folder* (editors/IDEs do; Finder and a few system utilities are filtered out), plus a
/// known-name fallback — so new editors (Cursor, Antigravity, Zed, …) appear automatically.
enum EditorList {
    /// Fallback names for editors that may not register folder handling.
    static let known = [
        "Visual Studio Code", "Cursor", "Antigravity", "VSCodium", "Windsurf", "Trae", "PearAI",
        "Void", "Zed", "Sublime Text", "Nova", "Fleet", "WebStorm", "IntelliJ IDEA", "PyCharm",
        "PhpStorm", "GoLand", "RubyMine", "CLion", "Android Studio", "Atom", "BBEdit", "TextMate",
    ]
    /// Apps returned by folder-open that aren't code editors.
    private static let exclude: Set<String> = [
        "Finder", "Owl Monitor", "Archive Utility", "DiskImageMounter", "Installer",
        "Script Editor", "Automator", "Quick Look", "ColorSync Utility",
    ]

    @MainActor static func installed() -> [String] {
        let ws = NSWorkspace.shared
        let fm = FileManager.default
        func names(for url: URL) -> Set<String> {
            Set(ws.urlsForApplications(toOpen: url).map {
                fm.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            })
        }
        // Editors register to open BOTH a folder and source files; Books/QuickTime open folders but
        // not code, browsers open code but not folders — so the intersection is just the editors.
        let folderOpeners = names(for: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        var codeOpeners: Set<String> = []
        // (avoid ".ts" — it's also an MPEG-TS video type, which would pull in media players)
        for ext in ["js", "tsx", "jsx", "py", "swift", "go", "rs", "php", "rb"] {
            let f = URL(fileURLWithPath: NSTemporaryDirectory() + "dm-probe." + ext)
            try? "x".write(to: f, atomically: true, encoding: .utf8)
            codeOpeners.formUnion(names(for: f))
            try? fm.removeItem(at: f)
        }
        var result = folderOpeners.intersection(codeOpeners).subtracting(exclude)
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for name in known where !result.contains(name)
            && dirs.contains(where: { fm.fileExists(atPath: $0 + "/" + name + ".app") }) {
            result.insert(name)
        }
        return result.sorted()
    }
}
