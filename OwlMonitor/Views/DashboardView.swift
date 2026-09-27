import SwiftUI
import AppKit

/// Per-project header card: identity and the live server status/run control in one compact row.
/// Open/Code and Build live in the window toolbar now (see `ProjectOpenGroup` / `ProjectBuildButton`);
/// Activity and the terminal are global (see ActivityView / GlobalTerminalView).
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Identity row: icon · name · git branch.
            HStack(spacing: 12) {
                ProjectIconView(project: project, size: 30)
                Text(project.name).font(.title2.bold()).lineLimit(1)
                    .help(project.path)
                BranchWorktreeMenu(project: project)
                UncommittedDiffStat(project: project)
                Spacer()
            }
            Divider()
            // One play/stop pill per run-control the project has — dev, worker, build, preview, … —
            // all from AppState.runControls(for:), so a new process type appears here automatically.
            HStack(spacing: 10) {
                ForEach(app.runControls(for: project)) { control in
                    RunControlButton(title: control.title, status: control.status, onToggle: control.onToggle)
                }
                Spacer(minLength: 0)
            }
            // Live CPU/RAM charts for the project's active dev/preview tree. Isolated in
            // SessionChartsView so its ~1 Hz churn doesn't re-render this card.
            if app.settings.showCharts, let session = activeSession {
                Divider()
                SessionChartsView(session: session)
            }
        }
        .dmCard()
    }

    /// The project's active supervised session — nil when nothing is live, so the charts stay hidden.
    private var activeSession: DevSession? { app.activeSession(for: project) }
}

/// Group 1 of the window toolbar: open the running server in the browser, the project in the editor,
/// and the project folder in Finder — as one united `ControlGroup` that matches the native
/// Settings/Doctor button style. Acts on the currently selected project.
struct ProjectOpenGroup: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let project = app.selectedProject {
            ControlGroup {
                // The LIVE server, dev OR preview. This used to read only the dev session, so with a
                // preview up the button vanished and the build it was serving couldn't be opened.
                if let port = app.activeSession(for: project)?.effectivePort {
                    Button { app.openInBrowser(project) } label: {
                        Label("Open in browser", systemImage: "globe")
                    }
                    .help("Open http://localhost:\(port) in \(app.settings.browser ?? "your browser")")
                }
                Button { app.openInEditor(project) } label: {
                    Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Open in \(app.settings.editor ?? "your editor")")
                Button { app.openInFinder(project) } label: {
                    Label("Open folder", systemImage: "folder")
                }
                .help("Open the project folder in Finder")
            }
        }
    }
}

// MARK: - Shared project actions

/// The actions behind the toolbar's open buttons AND the Server menu's keyboard shortcuts — one
/// implementation, so a click and a shortcut can never behave differently.
extension AppState {
    /// Projects grouped the way the sidebar shows them: by the folder the user dropped (`groupRoot`),
    /// else the immediate parent; groups in first-appearance order, projects keeping theirs. One
    /// definition, so the sidebar and ⌘1…⌘9 can never disagree about which project is "3".
    var projectGroups: [(id: String, name: String, projects: [Project])] {
        var order: [String] = []
        var byGroup: [String: [Project]] = [:]
        for p in projects {
            let key = p.groupRoot ?? URL(fileURLWithPath: p.path).deletingLastPathComponent().path
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(p)
        }
        return order.map { (id: $0, name: URL(fileURLWithPath: $0).lastPathComponent, projects: byGroup[$0]!) }
    }

    /// The project's live supervised server: dev if it's up, else a running preview (the two are
    /// mutually exclusive per project). nil when nothing is live.
    func activeSession(for project: Project) -> DevSession? {
        if let s = sessions[project.id], s.state.isActive { return s }
        if let p = previews[project.id], p.state.isActive { return p }
        return nil
    }

    /// `http://localhost:<port>/` of the project's live server, or nil when nothing is up.
    func serverURL(for project: Project) -> URL? {
        activeSession(for: project)?.effectivePort.flatMap { URL(string: "http://localhost:\($0)/") }
    }

    func openInBrowser(_ project: Project) {
        guard let url = serverURL(for: project) else { return }
        Self.open(target: url.absoluteString, withAppNamed: settings.browser, fallback: url)
    }

    func openInEditor(_ project: Project) {
        let editor = settings.editor ?? installedEditors.first ?? "Visual Studio Code"
        Self.open(target: project.path, withAppNamed: editor, fallback: URL(fileURLWithPath: project.path))
    }

    func openInFinder(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }

    /// Put the live server's URL on the clipboard. Returns whether there was one to copy.
    @discardableResult
    func copyServerURL(_ project: Project) -> Bool {
        guard let url = serverURL(for: project) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        return true
    }

    /// Clear the selected terminal tab's on-screen log (⌘K). The tab id encodes which runner it shows
    /// (`s:`/`p:`/`w:`/`b:` + project id); the Claude and pressure tabs have no log of their own.
    func clearSelectedTerminal() {
        guard let tab = selectedTerminalID else { return }
        for p in projects {
            switch tab {
            case "s:\(p.id)": sessions[p.id]?.clearLog()
            case "p:\(p.id)": previews[p.id]?.clearLog()
            case "w:\(p.id)": workers[p.id]?.clearLog()
            case "b:\(p.id)": builds[p.id]?.clearLog()
            default: continue
            }
            return
        }
    }

    /// `open -a <app> <target>`, falling back to the system default handler when no app is set, the
    /// launch fails, OR `open` exits non-zero. That last case is the one that bites: `run()` only
    /// throws if `/usr/bin/open` itself can't start, so a configured browser or editor that isn't
    /// installed used to fail silently — `open` reported it on exit and nothing opened at all.
    static func open(target: String, withAppNamed appName: String?, fallback: URL) {
        guard let appName, !appName.isEmpty else { NSWorkspace.shared.open(fallback); return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", appName, target]
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(fallback) }
        }
        do { try task.run() } catch { NSWorkspace.shared.open(fallback) }
    }
}

// The build control moved into the dashboard's run-control column (see RunControlRow), so the
// toolbar build button / "Build Running" label that used to live here are gone.
