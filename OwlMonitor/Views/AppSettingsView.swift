import SwiftUI
import AppKit

/// Settings modal styled like macOS System Settings: a left sidebar (General + one row per project)
/// and a grouped-form detail pane on the right. Server config defaults to Auto.
struct AppSettingsView: View {
    @Environment(AppState.self) private var app
    @State private var selection: Item = .general

    enum Item: Hashable {
        case general
        case aiTools
        case notifications
        case project(Project.ID)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(Item.general)
                Label("AI Tools", systemImage: "sparkles.rectangle.stack").tag(Item.aiTools)
                Label("Notifications", systemImage: "bell").tag(Item.notifications)
                Section("Projects") {
                    ForEach(app.projects) { p in
                        Label { Text(p.name) } icon: { ProjectIconView(project: p, size: 16) }
                            .tag(Item.project(p.id))
                    }
                }
            }
            // Brand + version above the settings categories — this is the app's "about" surface,
            // since there's no separate About window.
            .safeAreaInset(edge: .top) {
                BrandMark(size: 26, showsVersion: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:
            GeneralSettings()
        case .aiTools:
            AgentToolsSettings()
        case .notifications:
            NotificationsSettings()
        case .project(let id):
            if let p = app.projects.first(where: { $0.id == id }) {
                ProjectSettings(project: p) { selection = .general }
            } else {
                ContentUnavailableView("Project removed", systemImage: "folder.badge.minus")
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            ClaudeCodeSection()
            Section {
                Picker("Theme", selection: theme) {
                    ForEach(AppSettings.themes) { t in
                        Label(LocalizedStringKey(t.label), systemImage: t.icon).tag(t.id)
                    }
                }
                Picker("Terminal", selection: terminalTheme) {
                    ForEach(AppSettings.terminalThemes) { t in
                        Label(LocalizedStringKey(t.label), systemImage: t.icon).tag(t.id)
                    }
                }
                Picker("Language", selection: language) {
                    ForEach(AppSettings.languages, id: \.id) { Text(LocalizedStringKey($0.label)).tag($0.id) }
                }
            } header: {
                Text("Appearance")
            }
            Section("Open in") {
                Picker("Browser (Open)", selection: browser) {
                    Text("System default").tag(String?.none)
                    ForEach(app.installedBrowsers, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Editor (Code)", selection: editor) {
                    ForEach(app.installedEditors, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Activity bars") {
                ForEach(AppSettings.allBars) { bar in
                    Toggle(LocalizedStringKey(bar.label), isOn: barBinding(bar.id))
                }
                Toggle("Show timeline charts", isOn: showCharts)
            }
            Section("AI analysis") {
                Picker("Model", selection: model) {
                    ForEach(AppSettings.models) { Text($0.label).tag($0.id) }
                }
                LabeledContent("Used for") {
                    Text("Doctor: heavy processes, Owl Monitor diagnosis, memory.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Behavior") {
                Toggle("Auto-close orphaned dev processes under pressure", isOn: autoClose)
            }
            Section {
                Picker("Default heap for new projects", selection: defaultMem) {
                    ForEach(1...max(systemMaxGB, app.settings.defaultMemoryGB), id: \.self) {
                        Text("\($0) GB").tag($0)
                    }
                }
                Toggle(isOn: shareHeap) {
                    Text("Share RAM between servers")
                    Text(heapBudgetSummary)
                }
                Picker(selection: idleStop) {
                    ForEach(AppSettings.idleStopChoices, id: \.self) { minutes in
                        Text(idleStopLabel(minutes)).tag(minutes)
                    }
                } label: {
                    Text("Stop idle servers")
                    Text("Idle means no browser tab connected and no output. Frees its memory; start it again any time.")
                }
            } header: {
                Text("Memory")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    /// Heap options cap at the machine's physical RAM.
    private var systemMaxGB: Int { max(1, Int((app.systemSampler.totalMem / 1_073_741_824).rounded())) }

    private var browser: Binding<String?> {
        .init(get: { app.settings.browser }, set: { app.settings.browser = $0; app.persistSettings() })
    }
    private var editor: Binding<String> {
        .init(get: { app.settings.editor ?? app.installedEditors.first ?? "" },
              set: { app.settings.editor = $0; app.persistSettings() })
    }
    private var showCharts: Binding<Bool> {
        .init(get: { app.settings.showCharts }, set: { app.settings.showCharts = $0; app.persistSettings() })
    }
    private func barBinding(_ id: String) -> Binding<Bool> {
        .init(get: { app.settings.bars.contains(id) }, set: { on in
            if on {
                if !app.settings.bars.contains(id) { app.settings.bars.append(id) }
            } else {
                app.settings.bars.removeAll { $0 == id }
            }
            app.persistSettings()
        })
    }
    private var model: Binding<String> {
        .init(get: { app.settings.analysisModel }, set: { app.settings.analysisModel = $0; app.persistSettings() })
    }
    private var autoClose: Binding<Bool> {
        .init(get: { app.settings.autoCloseOrphans }, set: { app.settings.autoCloseOrphans = $0; app.persistSettings() })
    }
    private var shareHeap: Binding<Bool> {
        .init(get: { app.settings.shareHeapBudget }, set: { app.settings.shareHeapBudget = $0; app.persistSettings() })
    }
    private var idleStop: Binding<Int> {
        .init(get: { app.settings.idleStopMinutes }, set: { app.settings.idleStopMinutes = $0; app.persistSettings() })
    }
    /// What the budget works out to on THIS Mac, so the toggle explains itself in real numbers.
    private var heapBudgetSummary: String {
        let ram = systemMaxGB
        let reserve = MemoryGuard.reservedGB(systemGB: ram)
        let two = MemoryGuard.budgetedHeapGB(learnedGB: 99, floorGB: Project.minHeapGB, systemGB: ram, otherServers: 1)
        let three = MemoryGuard.budgetedHeapGB(learnedGB: 99, floorGB: Project.minHeapGB, systemGB: ram, otherServers: 2)
        return String(format: String(localized: "Heaps in auto mode split the %d GB left after %d GB for macOS: 2 servers get %d GB each, 3 get %d GB. A project that ran out of memory keeps what it needs."),
                      ram - reserve, reserve, two, three)
    }
    private func idleStopLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return String(localized: "Never")
        case let m where m % 60 == 0: return String(format: String(localized: "After %d h"), m / 60)
        default: return String(format: String(localized: "After %d min"), minutes)
        }
    }
    private var defaultMem: Binding<Int> {
        .init(get: { app.settings.defaultMemoryGB }, set: { app.settings.defaultMemoryGB = $0; app.persistSettings() })
    }
    private var theme: Binding<String> {
        .init(get: { app.settings.theme }, set: {
            app.settings.theme = $0; app.persistSettings(); AppSettings.applyAppearance($0)
        })
    }
    private var terminalTheme: Binding<String> {
        .init(get: { app.settings.terminalTheme }, set: { app.settings.terminalTheme = $0; app.persistSettings() })
    }
    private var language: Binding<String> {
        .init(get: { app.settings.language }, set: {
            app.settings.language = $0; app.persistSettings(); AppSettings.applyLanguage($0)
        })
    }
}

// MARK: - Notifications

private struct NotificationsSettings: View {
    @Environment(AppState.self) private var app
    /// Whether macOS has granted notification permission to the app (assume yes until checked).
    @State private var systemAuthorized = true

    var body: some View {
        Form {
            if !systemAuthorized {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notifications are turned off in macOS", systemImage: "bell.slash.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        Text("Owl Monitor can't show banners until you allow them in "
                             + "System Settings → Notifications.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open System Settings") { Self.openSystemNotificationSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                Toggle("Enable notifications", isOn: master)
            } footer: {
                Text("Native banners for supervision events. Urgent ones (crash, failure, system "
                     + "pressure) play a sound and can break through Focus; the rest are silent. The "
                     + "last 5 also appear at the bottom of the sidebar.")
            }
            Section("Categories") {
                ForEach(NotificationCatalog.all, id: \.id) { c in
                    Toggle(isOn: categoryBinding(c.id)) {
                        Label(c.label, systemImage: c.systemImage)
                    }
                    .disabled(!app.settings.notificationsEnabled)
                }
            }
            Section {
                TextField("https://hooks.slack.com/… or Discord webhook", text: webhookURL)
                    .textContentType(.URL).autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                if !app.settings.notifyWebhookURL.isEmpty && !WebhookNotifier.isValid(app.settings.notifyWebhookURL) {
                    Label("Not a valid http(s) URL — won't be sent.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Webhook")
            } footer: {
                Text("Also POST every enabled notification to this Slack/Discord/incoming webhook. "
                     + "One JSON body carries both `text` (Slack) and `content` (Discord). Leave empty to disable.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .onAppear { Notifier.shared.authorizationGranted { systemAuthorized = $0 } }
    }

    /// Open System Settings ▸ Notifications so the user can re-enable banners for the app.
    static func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    private var master: Binding<Bool> {
        .init(get: { app.settings.notificationsEnabled },
              set: { app.settings.notificationsEnabled = $0; app.persistSettings() })
    }
    private var webhookURL: Binding<String> {
        .init(get: { app.settings.notifyWebhookURL },
              set: { app.settings.notifyWebhookURL = $0.trimmingCharacters(in: .whitespaces); app.persistSettings() })
    }

    private func categoryBinding(_ c: NotificationCategory) -> Binding<Bool> {
        .init(get: {
            switch c {
            case .failures: return app.settings.notifyFailures
            case .recovery: return app.settings.notifyRecovery
            case .builds:   return app.settings.notifyBuilds
            case .pressure: return app.settings.notifyPressure
            }
        }, set: { on in
            switch c {
            case .failures: app.settings.notifyFailures = on
            case .recovery: app.settings.notifyRecovery = on
            case .builds:   app.settings.notifyBuilds = on
            case .pressure: app.settings.notifyPressure = on
            }
            app.persistSettings()
        })
    }
}

// MARK: - Claude Code hook (install / uninstall)

/// Lets the user install (or remove) the `owl-monitor` CLI and the global Claude Code hook that makes
/// OTHER Claude sessions route dev servers through this app instead of launching them themselves.
/// Shown first in General. The CLI comes first — it's what the hook tells agents to run.
private struct ClaudeCodeSection: View {
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var cliError: String?
    @State private var hookInstalled = ClaudeHookInstaller.isInstalled
    @State private var hookError: String?

    var body: some View {
        Section("Claude Code") {
            // MARK: CLI (owl-monitor)
            LabeledContent("Command-line tool (owl-monitor)") {
                Label(cliInstalled ? "Installed" : "Not installed",
                      systemImage: cliInstalled ? "checkmark.seal.fill" : "circle")
                    .foregroundStyle(cliInstalled ? Color.green : .secondary)
                    .labelStyle(.titleAndIcon)
            }
            Text("Symlinks `owl-monitor` into `~/.local/bin`, pointing at the copy inside this app — so "
                 + "the CLI always matches the running app. Drive builds/servers from any terminal, and "
                 + "the hook below routes agents through it.")
                .font(.caption).foregroundStyle(.secondary)
            if cliInstalled && !CLIInstaller.isOnPATH {
                Label("`~/.local/bin` isn't on your PATH — add it so `owl-monitor` is found.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if cliInstalled {
                    Button(role: .destructive) { runCLI(CLIInstaller.uninstall) } label: {
                        Label("Uninstall CLI", systemImage: "trash")
                    }
                } else {
                    Button { runCLI(CLIInstaller.install) } label: {
                        Label("Install CLI", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let cliError {
                Label(cliError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }

            Divider()

            // MARK: PreToolUse hook
            LabeledContent("Route dev servers through the app") {
                Label(hookInstalled ? "Installed" : "Not installed",
                      systemImage: hookInstalled ? "checkmark.seal.fill" : "circle")
                    .foregroundStyle(hookInstalled ? Color.green : .secondary)
                    .labelStyle(.titleAndIcon)
            }
            Text("Other Claude Code sessions are blocked from running `npm run dev` / `nuxt dev` / "
                 + "builds directly and told to use `owl-monitor`, so every server is supervised here. "
                 + "Adds a PreToolUse hook to ~/.claude/settings.json.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if hookInstalled {
                    Button(role: .destructive) { runHook(ClaudeHookInstaller.uninstall) } label: {
                        Label("Uninstall hook", systemImage: "trash")
                    }
                } else {
                    Button { runHook(ClaudeHookInstaller.install) } label: {
                        Label("Install hook", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let hookError {
                Label(hookError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            cliInstalled = CLIInstaller.isInstalled
            hookInstalled = ClaudeHookInstaller.isInstalled
        }
    }

    private func runCLI(_ action: () throws -> Void) {
        do { try action(); cliError = nil } catch { cliError = error.localizedDescription }
        cliInstalled = CLIInstaller.isInstalled
    }

    private func runHook(_ action: () throws -> Void) {
        do { try action(); hookError = nil } catch { hookError = error.localizedDescription }
        hookInstalled = ClaudeHookInstaller.isInstalled
    }
}

// MARK: - Per-project

/// Editor for a project's user-defined environment variables. Ordered rows (stable `id`), each a
/// KEY/value pair; edits write straight back through the binding (persisted like every other
/// per-project setting) and take effect on the next launch of any supervised run.
private struct EnvSection: View {
    @Binding var env: [Project.EnvVar]

    var body: some View {
        Section {
            ForEach($env) { $row in
                HStack(spacing: 8) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .frame(width: 150)
                    Text("=").foregroundStyle(.secondary)
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                    Button { env.removeAll { $0.id == row.id } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Remove this variable")
                }
            }
            Button { env.append(Project.EnvVar(key: "", value: "")) } label: {
                Label("Add variable", systemImage: "plus")
            }
        } header: {
            Text("Environment")
        } footer: {
            Text("Injected into the dev server, preview, build, and worker on their next launch. "
                 + "The app's own PORT / NODE_OPTIONS override a variable of the same name.")
        }
    }
}

private struct ProjectSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: Project
    let onRemoved: () -> Void

    private var live: Project { app.projects.first { $0.id == project.id } ?? project }

    var body: some View {
        Form {
            Section("Server") {
                memoryRow
                buildMemoryRow
                portRow
                packageRow
                healthPathRow
            }
            EnvSection(env: Binding(get: { live.env }, set: { app.setEnv($0, for: project.id) }))
            Section {
                LabeledContent("Folder") {
                    Text(live.path).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button(role: .destructive) {
                    app.removeProject(project.id); onRemoved()
                } label: {
                    Label("Remove project", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
    }

    /// Heap options cap at the machine's physical RAM (always include the current value).
    private var systemMaxGB: Int { max(1, Int((app.systemSampler.totalMem / 1_073_741_824).rounded())) }

    private var memoryRow: some View {
        let auto = Binding(get: { live.memoryAuto }, set: { app.setMemoryAuto($0, for: project.id) })
        return row(icon: "memorychip.fill", name: "Memory", auto: auto) {
            Text("\(app.effectiveMemoryGB(for: live)) GB").foregroundStyle(.secondary)
        } manual: {
            Picker("", selection: Binding(get: { live.memoryGB },
                                          set: { app.setMemoryGB($0, for: project.id) })) {
                ForEach(1...max(systemMaxGB, live.memoryGB), id: \.self) { Text("\($0) GB").tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    /// Build heap — independent from the dev server. In auto it shows the autoscaler's learned level
    /// (4→6→8); in manual a fixed GB picker.
    private var buildMemoryRow: some View {
        let auto = Binding(get: { live.buildMemoryAuto }, set: { app.setBuildMemoryAuto($0, for: project.id) })
        return row(icon: "hammer", name: "Build memory", auto: auto) {
            Text("\(app.effectiveBuildMemoryGB(for: live)) GB").foregroundStyle(.secondary)
        } manual: {
            Picker("", selection: Binding(get: { live.buildMemoryGB },
                                          set: { app.setBuildMemoryGB($0, for: project.id) })) {
                ForEach(1...max(systemMaxGB, live.buildMemoryGB), id: \.self) { Text("\($0) GB").tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private var portRow: some View {
        let auto = Binding(get: { live.port == nil },
                           set: { isAuto in app.setPort(isAuto ? nil : (live.port ?? 3000), for: project.id) })
        return row(icon: "network", name: "Port", auto: auto) {
            Text("auto").foregroundStyle(.secondary)
        } manual: {
            TextField("3000", value: Binding(get: { live.port }, set: { app.setPort($0, for: project.id) }),
                      format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder).frame(width: 74)
        }
    }

    /// Health-probe path — "auto" means "/". Manual lets an API-only server point the liveness check
    /// at a real route (e.g. "/health") when "/" hangs or has no handler. Applies on next launch.
    private var healthPathRow: some View {
        let auto = Binding(get: { live.healthPath == nil },
                           set: { isAuto in app.setHealthPath(isAuto ? nil : live.effectiveHealthPath, for: project.id) })
        return row(icon: "stethoscope", name: "Health path", auto: auto) {
            Text("/").foregroundStyle(.secondary)
        } manual: {
            TextField("/health", text: Binding(get: { live.healthPath ?? "" },
                                               set: { app.setHealthPath($0, for: project.id) }))
                .textFieldStyle(.roundedBorder).frame(width: 120)
        }
    }

    private var packageRow: some View {
        let auto = Binding(get: { live.packageManagerAuto }, set: { app.setPackageManagerAuto($0, for: project.id) })
        return row(icon: "shippingbox", name: "Package", auto: auto) {
            Text(live.packageManager.rawValue).foregroundStyle(.secondary)
        } manual: {
            Picker("", selection: Binding(get: { live.packageManager },
                                          set: { app.setPackageManager($0, for: project.id) })) {
                ForEach(PackageManager.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    /// A settings row: label (left), the auto value or the manual control (right), and the Auto
    /// switch. The switch alone carries the "auto" meaning — the word isn't repeated.
    @ViewBuilder private func row<AutoValue: View, Manual: View>(
        icon: String, name: LocalizedStringKey, auto: Binding<Bool>,
        @ViewBuilder autoValue: () -> AutoValue, @ViewBuilder manual: () -> Manual
    ) -> some View {
        HStack(spacing: 12) {
            Label(name, systemImage: icon)
            Spacer(minLength: 8)
            // Layered, not inline: flipping the switch cross-fades the auto value into the manual
            // control IN PLACE — side by side in the HStack they'd briefly shove each other sideways.
            ZStack(alignment: .trailing) {
                if auto.wrappedValue {
                    autoValue().transition(.rise(reduceMotion: reduceMotion))
                } else {
                    manual().transition(.rise(reduceMotion: reduceMotion))
                }
            }
            Toggle("", isOn: auto).labelsHidden().toggleStyle(.switch)
        }
        .animation(Motion.state(reduceMotion), value: auto.wrappedValue)
    }
}
