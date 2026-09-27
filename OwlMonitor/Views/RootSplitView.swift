import SwiftUI
import AppKit

struct RootSplitView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailTop
                // Toolbar lives on the detail content (not the split-view root) so ToolbarSpacer
                // actually splits the trailing items into separate Liquid Glass groups:
                // 1) Keep Awake · 2) Open · 3) Settings + Doctor.
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        SleepGuardToggle()
                    }
                    // Hide the toolbar's auto glass wrapper for this item — it was a tall oval around
                    // our narrow control. We draw our own CIRCULAR glass in the label instead.
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.fixed)
                    // Build/worker/dev controls live in the dashboard card now (see RunControlRow).
                    ToolbarItem {
                        ProjectOpenGroup()
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItemGroup {
                        Button { openWindow(id: "settings") } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("App settings")
                        Button { openWindow(id: "doctor") } label: {
                            Label("Doctor", systemImage: "stethoscope")
                        }
                        .help("Doctor Claude")
                        Button { openWindow(id: "history") } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .help("Event history (crashes, recycles, builds, pressure)")
                    }
                }
        }
        .navigationTitle("Owl Monitor")
        // A launch is likely soon after either of these: warm the login-shell PATH in the background
        // now, so pressing Start (or ⌘R) never freezes the window resolving it — see ShellEnvironment.
        .onChange(of: app.selectedProjectID) { ShellEnvironment.prefetch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ShellEnvironment.prefetch()
        }
    }

    /// Toolbar control for `AppState.sleepGuard`: clicking asks how long to keep the Mac from
    /// sleeping or dimming its display, so a long build/dev session isn't interrupted. Session-only
    /// — always starts off on launch, exactly like `caffeinate`.
    private struct SleepGuardToggle: View {
        @Environment(AppState.self) private var app

        private static let durations: [(label: String, seconds: TimeInterval?)] = [
            ("15 Minutes", 15 * 60),
            ("30 Minutes", 30 * 60),
            ("1 Hour", 60 * 60),
            ("2 Hours", 2 * 60 * 60),
            ("Indefinitely", nil),
        ]

        private static let diameter: CGFloat = 34   // match the height of the sibling toolbar buttons

        var body: some View {
            let active = app.sleepGuard.isActive
            let activeUntil = app.sleepGuard.activeUntil
            let totalDuration = app.sleepGuard.totalDuration
            // The toolbar's own glass is hidden for this item (see `.sharedBackgroundVisibility`),
            // so we draw a fixed-size square face + `.glassEffect(in: .circle)` — a guaranteed 1:1
            // circular glass matching the other toolbar buttons' material. The cup uses the standard
            // label colour when off (matching the code/folder icons) and turns orange when active,
            // ringed by the orange countdown gauge.
            Menu {
                if active {
                    Button("Turn Off", role: .destructive) { app.sleepGuard.disable() }
                    Divider()
                }
                ForEach(Self.durations, id: \.label) { option in
                    Button(option.label) { app.sleepGuard.enable(for: option.seconds) }
                }
            } label: {
                ZStack {
                    if active { ring(activeUntil: activeUntil, totalDuration: totalDuration) }
                    Image(systemName: active ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(active ? Color.orange : Color.primary)
                }
                .frame(width: Self.diameter, height: Self.diameter)
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)   // our glassEffect IS the background — no extra button chrome
            .help(active ? "Keep Awake is ON — the Mac won't sleep or dim its display"
                          : "Keep the Mac from sleeping or dimming its display")
        }

        /// The orange countdown gauge, inset a hair so it hugs the circular rim. Timed → a faint
        /// track with the remaining fraction over it; indefinite → one solid full ring. It fills
        /// from the RIGHT (the `scaleEffect(x: -1)` mirror flips the default left-side drain), so the
        /// arc drains down the right edge from 12 o'clock.
        private func ring(activeUntil: Date?, totalDuration: TimeInterval?) -> some View {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let fraction = SleepGuard.remainingFraction(
                    activeUntil: activeUntil, totalDuration: totalDuration, now: context.date)
                ZStack {
                    if let fraction {
                        Circle().stroke(Color.orange.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .scaleEffect(x: -1, y: 1)   // drain on the RIGHT, not the left
                    } else {
                        Circle().stroke(Color.orange, lineWidth: 2)
                    }
                }
                .padding(1.5)
                .allowsHitTesting(false)   // the menu underneath owns the taps
            }
        }
    }

    /// The detail stack: the selected project's header card (or a placeholder), the GLOBAL Activity
    /// card, and — while something is running — the GLOBAL terminal as another card below, filling
    /// the remaining height. All sit on the window-tinted base.
    @ViewBuilder private var detailTop: some View {
        let showsTerminal = !app.sessions.isEmpty || !app.builds.isEmpty || !app.workers.isEmpty
            || !app.previews.isEmpty || app.systemUnderPressure
            // `hasClaudeShells`, not `processes`: reading `processes` here re-evaluated this whole
            // detail stack on every 2 s sampler tick; the derived flag changes only when a Claude
            // shell actually appears or exits.
            || app.systemSampler.hasClaudeShells
        VStack(spacing: 14) {
            // A ZStack, not a bare `if` in the VStack: while switching projects the outgoing and
            // incoming dashboards briefly coexist, and stacked vertically they'd shove the Activity
            // card down for a frame. Layered, the new one simply fades up over the old.
            ZStack(alignment: .top) {
                if let project = app.selectedProject {
                    // Keyed by project, so switching (sidebar or ⌘1…⌘9) swaps in a fresh card with the
                    // house entrance — otherwise near-identical cards change in place and the switch
                    // is easy to miss.
                    DashboardView(project: project)
                        .id(project.id)
                        .transition(.rise(reduceMotion: reduceMotion))
                } else {
                    Label("No project selected — add one with + and pick it in the sidebar.",
                          systemImage: "square.dashed")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dmCard()
                        .transition(.rise(reduceMotion: reduceMotion))
                }
            }
            .animation(Motion.state(reduceMotion), value: app.selectedProjectID)
            ActivityView()
            if showsTerminal {
                // The terminal arrives with the first process and leaves with the last.
                GlobalTerminalView()
                    .transition(.rise(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.region(reduceMotion), value: showsTerminal)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
