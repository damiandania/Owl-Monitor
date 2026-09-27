import SwiftUI
import AppKit

@main
struct OwlMonitorApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Notifications are wired in AppState.init (Notifier.attach): delegate, categories, authorization.

    var body: some Scene {
        // Single main window (not a WindowGroup): "Open Window" focuses the existing one
        // instead of spawning duplicates.
        Window("Owl Monitor", id: "main") {
            RootSplitView()
                .environment(appState)
                .environment(\.locale, appState.uiLocale)
                .frame(minWidth: 800, minHeight: 600)
                // Hand the shared AppState to the AppDelegate so the always-visible quota HUD (a
                // detached AppKit panel) can build the same menu the old MenuBarExtra showed.
                .onAppear { delegate.attach(appState: appState) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            ServerCommands(app: appState)
        }

        // The menu-bar item (MenuBarExtra) is gone: macOS hides menu-bar icons behind the notch, so
        // its role — the constellation status glyph + the controls menu — now lives in the always-
        // visible quota HUD beside the notch (see QuotaHUD / AppDelegate).

        // Settings and Doctor are real windows (native title bar + traffic-light close button).
        Window("Settings", id: "settings") {
            AppSettingsView().environment(appState).environment(\.locale, appState.uiLocale)
        }
        .windowResizability(.contentSize)

        Window("Doctor", id: "doctor") {
            DoctorSheet().environment(appState).environment(\.locale, appState.uiLocale)
        }
        .windowResizability(.contentSize)

        Window("History", id: "history") {
            HistoryView().environment(appState).environment(\.locale, appState.uiLocale)
        }
        .windowResizability(.contentSize)
    }
}

/// The Server menu: every run action for the selected project, with keyboard shortcuts. The app had
/// none before — every start, stop, build or open meant reaching for the mouse. Items act on the
/// sidebar's selection and disable themselves when they can't apply.
///
/// Each action re-reads `app.selectedProject` WHEN IT RUNS rather than capturing the value the menu
/// was built with: the titles and enabled states are best-effort, but a stale capture would make ⌘R
/// restart a project that's no longer selected. Every action is also a safe no-op when it doesn't
/// apply, so a menu that lags a state change can't do harm.
struct ServerCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // ⌘, is THE macOS Settings shortcut, but Settings is a plain `Window` (for its native title
        // bar) and only a `Settings` scene gets ⌘, for free — so it was never bound.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",")
        }

        CommandMenu("Server") {
            let project = app.selectedProject
            let devUp = project.map { app.sessions[$0.id]?.state.isActive == true } ?? false
            let live = project.flatMap { app.activeSession(for: $0) } != nil
            let building = project.flatMap { app.builds[$0.id]?.isRunning } ?? false

            Button(devUp ? "Restart" : "Start") {
                guard let p = app.selectedProject else { return }
                if let s = app.sessions[p.id], s.state.isActive { s.recycle() } else { app.launch(p) }
            }
            .keyboardShortcut("r")
            .disabled(project == nil)

            Button("Stop") {
                guard let p = app.selectedProject else { return }
                app.stop(p)
                app.stopPreview(p)   // dev and preview are mutually exclusive — stop whichever runs
            }
            .keyboardShortcut(".")
            .disabled(!live)

            // Hand RAM back in one go: stop every server except the one you're working on.
            let others = app.otherLiveServerCount(keeping: project)
            Button {
                app.stopOtherServers(keeping: app.selectedProject)
            } label: {
                // Separate keys (not one interpolated string) so each language gets a real sentence.
                switch others {
                case 0: Text("Stop Other Servers")
                case 1: Text("Stop 1 Other Server")
                default: Text("Stop \(others) Other Servers")
                }
            }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(others == 0)

            Divider()

            Button("Build") { if let p = app.selectedProject { app.runBuild(p) } }
                .keyboardShortcut("b")
                .disabled(project?.buildCommand == nil || building)

            Button("Preview Production Build") { if let p = app.selectedProject { app.startPreview(p) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(project?.previewCommand == nil)

            Divider()

            Button("Open in Browser") { if let p = app.selectedProject { app.openInBrowser(p) } }
                .keyboardShortcut("o")
                .disabled(!live)

            Button("Copy URL") { if let p = app.selectedProject { app.copyServerURL(p) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!live)

            Button("Open in Editor") { if let p = app.selectedProject { app.openInEditor(p) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(project == nil)

            Button("Reveal in Finder") { if let p = app.selectedProject { app.openInFinder(p) } }
                .disabled(project == nil)

            Divider()

            Button("Clear Log") { app.clearSelectedTerminal() }
                .keyboardShortcut("k")

            Divider()

            // ⌘1…⌘9 in sidebar order (AppState.projectGroups), so "3" is the third row you see.
            let ordered = app.projectGroups.flatMap(\.projects)
            ForEach(Array(ordered.prefix(9).enumerated()), id: \.element.id) { index, p in
                Button(p.name) { app.selectedProjectID = p.id }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
    }
}

/// Hosts the always-visible quota HUD (a floating panel beside the notch). Kept in an AppDelegate
/// because it's a plain AppKit window with no place in the SwiftUI scene graph, and it must come up
/// once at launch and live for the whole app session.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let claudeQuota = ClaudeQuotaMonitor()
    private let gptQuota = CodexQuotaMonitor()
    private var quotaHUD: QuotaHUDController?

    /// Called once from the main window's `onAppear` with the app's shared state — the HUD needs it to
    /// build the controls menu. Guarded so a window reopen doesn't spawn a second HUD.
    func attach(appState: AppState) {
        guard quotaHUD == nil else { return }
        // One continuous notch bar: project-status icons (left) + notch + quota readout (right).
        quotaHUD = QuotaHUDController(claudeQuota: claudeQuota, gptQuota: gptQuota, appState: appState)
    }
}

/// The menu-bar icon: the logo's 7-dot constellation, drawn one dot per *live* process — each tinted
/// by that process's OWN status (running green ▸ starting orange ▸ failed/stopped red). So two
/// servers, one green and one red, show as two differently-coloured dots instead of a single
/// aggregate dot that's red whenever anything is red. The first process takes the centre slot; each
/// further one fills a scattered slot (fixed order, so dots don't flicker); past 7 they're not shown.
/// Unused slots use `labelColor` so they adapt like every other menu-bar icon (black/white).
struct MenuBarStatusIcon: View {
    @Environment(AppState.self) private var app
    /// Colour for the resting (no live process) dots. Defaults to `labelColor`; the quota HUD passes a
    /// wallpaper-reactive black/white so the glyph tracks the desktop like a real menu-bar item.
    var restColor: NSColor = .labelColor

    private static let iconSize: CGFloat = 18                 // menu-bar glyph size (points)
    private static let dotRadiusRatio: CGFloat = 0.115        // dot radius ÷ icon size

    /// Dot-slot centres (normalized, SVG top-down y — from `logo.svg`), in a fixed *scattered* order:
    /// centre, then corners and edges. Index = the Nth live process.
    private static let slots: [(x: CGFloat, y: CGFloat)] = [
        (0.500, 0.500),  // centre — the first process
        (0.830, 0.326),  // top-right
        (0.170, 0.686),  // bottom-left
        (0.169, 0.326),  // top-left
        (0.831, 0.684),  // bottom-right
        (0.500, 0.171),  // top
        (0.500, 0.830),  // bottom
    ]

    /// One colour per live run-control (dev/worker/build/preview, any project), by its own status.
    /// Stable order, capped at the slot count.
    private var dotColors: [NSColor] {
        app.projects.flatMap { app.runControls(for: $0) }
            .filter(\.isLive)
            // By launch time → the first/oldest process holds the centre slot and each newer one fills
            // the next scattered slot (tabID breaks ties so the order stays stable between renders).
            .sorted { ($0.startedAt ?? .distantPast, $0.tabID) < ($1.startedAt ?? .distantPast, $1.tabID) }
            .prefix(Self.slots.count)
            .map { NSColor($0.status.color) }
    }

    var body: some View {
        // A drawing-handler NSImage is THE way to do a menu-bar icon: it sizes correctly and AppKit
        // re-runs the handler on redraw, so `labelColor` tracks the menu bar's light/dark appearance.
        // A new NSImage is built whenever the dot colours change (a process starts/stops/changes state).
        let colors = dotColors
        return Image(nsImage: Self.icon(dots: colors, rest: restColor))
            .renderingMode(.original)
            .accessibilityLabel("Owl Monitor")
            .accessibilityValue(colors.isEmpty ? "idle"
                : "\(colors.count) active process\(colors.count == 1 ? "" : "es")")
    }

    /// Draw the full 7-dot constellation: the first N slots take live processes' status colours, the
    /// rest use `rest` (resting/unused), so the logo is always visible.
    private static func icon(dots: [NSColor], rest: NSColor) -> NSImage {
        let size = iconSize
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let r = size * dotRadiusRatio
            for (i, slot) in slots.enumerated() {
                let color = i < dots.count ? dots[i] : rest
                color.setFill()
                let cx = slot.x * size
                let cy = (1 - slot.y) * size   // SVG is top-down; AppKit drawing is bottom-up
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
    }
}
