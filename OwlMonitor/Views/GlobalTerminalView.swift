import SwiftUI
import AppKit

/// Global terminal panel: one tab per live run-control across ALL projects (dev, worker, build,
/// preview, … — straight from `AppState.runControls`, so a new process type appears automatically),
/// plus a yellow "System pressure" tab when the machine is stuck. Each tab is "icon + project name +
/// status dot / ✕ on hover".
struct GlobalTerminalView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shared by every tab's selection capsule so choosing another tab slides it there.
    @Namespace private var tabSelection

    private enum Tab: Identifiable {
        case control(RunControl)
        case claude(ProcessRow)
        case pressure
        var id: String {
            switch self {
            case .control(let c): c.tabID
            case .claude(let r): "claude:\(r.id)"
            case .pressure: "pressure"
            }
        }
    }

    private var tabs: [Tab] {
        var controls = app.projects.flatMap { app.runControls(for: $0) }.filter(\.isLive)
        controls.sort { ($0.projectName, $0.rank) < ($1.projectName, $1.rank) }
        var result: [Tab] = controls.map { .control($0) }
        // Claude Code's own shells/monitors get their own tabs (rightmost), each closeable — like a
        // terminal tab, but the "log" is the command/script it's running (its stdout isn't ours to
        // tap). `claudeShells` (not `processes`) so the tab strip re-evaluates only when a shell
        // appears/exits, not on every 2 s metrics tick.
        result += app.systemSampler.claudeShells.map { .claude($0) }
        // The pressure tab is an alert — always first (leftmost).
        if app.systemUnderPressure { result.insert(.pressure, at: 0) }
        return result
    }

    /// The selected tab, falling back to the first when the stored selection is gone (e.g. closed).
    private var selectedID: String? {
        let ids = tabs.map(\.id)
        if let sel = app.selectedTerminalID, ids.contains(sel) { return sel }
        return ids.first
    }

    var body: some View {
        let tabs = tabs
        let sel = selectedID
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tabs) {
                        pill(for: $0, selected: $0.id == sel)
                            .transition(.pop(reduceMotion: reduceMotion))
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 1)
                // Tabs pop in and out as servers start and stop; the selection capsule slides to the
                // chosen tab (dropped under Reduce Motion, where it simply moves).
                .animation(Motion.state(reduceMotion), value: tabs.map(\.id))
                .animation(Motion.spatial(reduceMotion), value: sel)
            }
            .scrollIndicators(.hidden)

            if let sel, let tab = tabs.first(where: { $0.id == sel }) {
                pane(for: tab)
            }
        }
        .dmCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func pill(for tab: Tab, selected: Bool) -> some View {
        switch tab {
        case .control(let c):
            TabPill(icon: c.icon, name: c.projectName, help: "\(c.title) · \(c.projectName)",
                    isPressure: false, selected: selected, namespace: tabSelection, tint: c.status.color,
                    onSelect: { app.selectedTerminalID = c.tabID },
                    closeHelp: "Close \(c.title.lowercased()) · \(c.projectName)", onClose: c.onClose)
        case .claude(let row):
            TabPill(icon: "terminal", assetIcon: "ClaudeLogo", name: row.name,
                    help: "\(row.name) — pid \(row.id)",
                    isPressure: false, selected: selected, namespace: tabSelection, tint: .red,
                    onSelect: { app.selectedTerminalID = "claude:\(row.id)" },
                    closeHelp: "Stop \(row.name) (pid \(row.id))",
                    onClose: { app.killProcessRow(row) })
        case .pressure:
            TabPill(icon: "exclamationmark.triangle.fill", name: "System pressure",
                    help: "System under pressure — suggested processes to free up",
                    isPressure: true, selected: selected, namespace: tabSelection, tint: .yellow,
                    onSelect: { app.selectedTerminalID = "pressure" },
                    closeHelp: "Dismiss pressure suggestions", onClose: { app.dismissPressure() })
        }
    }

    @ViewBuilder private func pane(for tab: Tab) -> some View {
        switch tab {
        case .pressure:
            ScrollView { PressureSuggestionsView().frame(maxWidth: .infinity, alignment: .leading) }
        case .control(let c):
            LogPaneView(lines: c.logLines(),
                        footer: c.timerMode.map { AnyView(RunTimerBar(mode: $0)) },
                        terminalTheme: app.settings.terminalTheme)
        case .claude(let row):
            ClaudeShellPane(shell: row)
        }
    }

    /// A tab pill: icon + project name (tap to select). Terminal tabs show a status dot that swaps to
    /// an ✕ on hover; the pressure tab is yellow with a warning glyph.
    private struct TabPill: View {
        let icon: String
        /// Asset-catalog image name; when set it's rendered instead of the SF Symbol `icon` (e.g. the
        /// Claude mark on a Claude shell tab). Tints with the pill's foreground, like a symbol.
        var assetIcon: String? = nil
        let name: String
        let help: String
        let isPressure: Bool
        let selected: Bool
        let namespace: Namespace.ID
        let tint: Color
        let onSelect: () -> Void
        let closeHelp: String
        let onClose: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    iconView
                    Text(name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .help(help)

                trailing.frame(width: 14, height: 14)   // fixed slot so dot↔✕ never shifts layout
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background {
                if selected {
                    // ONE selection capsule shared by every tab, so choosing another tab SLIDES it
                    // there — showing where the selection went — instead of one capsule vanishing
                    // and another appearing. Its fill cross-fades too (accent ↔ pressure yellow).
                    Capsule().fill(background)
                        .matchedGeometryEffect(id: "terminal-tab-selection", in: namespace)
                } else {
                    Capsule().fill(background)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.feedback, value: hovering)
        }

        @ViewBuilder private var iconView: some View {
            if let assetIcon {
                Image(assetIcon).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 11, height: 11)
            } else {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
        }

        private var foreground: Color {
            if isPressure { return selected ? .black : .pressureAmber }
            return selected ? .white : .primary
        }

        private var background: AnyShapeStyle {
            if isPressure {
                return AnyShapeStyle(selected ? Color.yellow.opacity(0.9) : Color.yellow.opacity(0.22))
            }
            return selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.quaternaryLabelColor))
        }

        @ViewBuilder private var trailing: some View {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
                }
                .buttonStyle(.plain)
                .help(closeHelp)
            } else {
                StatusDot(color: tint)
            }
        }
    }

    /// The pane for a Claude shell/monitor tab: its command/script (the "what it does") + a Stop
    /// button. Owl Monitor didn't spawn these, so their live stdout can't be captured — the command
    /// is the closest thing to a log. Metrics/command refresh from the sampler's live row.
    private struct ClaudeShellPane: View {
        @Environment(AppState.self) private var app
        let shell: ProcessRow
        @State private var command = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image("ClaudeLogo").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 13, height: 13).foregroundStyle(.primary)
                    Text(shell.name).fontWeight(.semibold).foregroundStyle(.red)
                    Text("pid \(shell.id)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(metrics).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(role: .destructive) { app.killProcessRow(shell) } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Stop \(shell.name) (pid \(shell.id))")
                }
                ScrollView {
                    Text(command.isEmpty ? "resolving…" : command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: .infinity)
                Text(shell.name.localizedCaseInsensitiveContains("monitor")
                     ? "A background monitor — a polling loop Claude left running. Its live output isn't captured (Owl Monitor didn't start it)."
                     : "Live output isn't captured — Owl Monitor didn't start this shell, so it can't tap its stdout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: shell.id) { command = Self.command(fromArgv: AppState.argv(of: shell.id)) }
        }

        private var metrics: String {
            // The tab's `shell` row comes from the membership-gated `claudeShells` list, whose
            // CPU/mem snapshot is frozen at the last membership change — read the LIVE row here, so
            // only this small pane (not the tab strip) re-renders on each metrics tick.
            let live = app.systemSampler.processes.first { $0.id == shell.id } ?? shell
            let mem = live.memBytes >= 1_073_741_824
                ? String(format: "%.1f GB", live.memBytes / 1_073_741_824)
                : "\(Int(live.memBytes / 1_048_576)) MB"
            return String(format: "%.0f%% · %@", live.cpuPerCore, mem)
        }

        /// The real command a Claude shell runs — everything after the `source <snapshot> … && `
        /// preamble its Bash tool prepends; falls back to the raw argv (minus a leading `-c`).
        static func command(fromArgv argv: String) -> String {
            if let snap = argv.range(of: "shell-snapshots/snapshot-"),
               let amp = argv.range(of: "&& ", range: snap.upperBound..<argv.endIndex) {
                let cmd = argv[amp.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !cmd.isEmpty { return cmd }
            }
            if let r = argv.range(of: "-c ") { return String(argv[r.upperBound...]) }
            return argv.isEmpty ? "(no command captured)" : argv
        }
    }
}
