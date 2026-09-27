import SwiftUI
import AppKit

/// A visual inventory of the skills, installed plugins and MCP connectors available globally or in
/// one supervised project. The inventory is deliberately read-only except for existing skill actions.
struct AgentToolsSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scope: Scope = .global
    @State private var category: Category = .skills
    @State private var snapshot = AgentToolCatalog.Snapshot()
    @State private var pendingDeletion: SkillCatalog.Skill?
    @State private var errorMessage: String?
    @State private var cliSearch = ""

    private enum Scope: Hashable { case global, project(Project.ID) }
    private enum Category: String, CaseIterable, Identifiable {
        case skills = "Skills"
        case plugins = "Plugins"
        case connectors = "MCP"
        case commandLineTools = "CLIs"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .skills: return "puzzlepiece.extension.fill"
            case .plugins: return "shippingbox.fill"
            case .connectors: return "network"
            case .commandLineTools: return "terminal.fill"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                switch category {
                case .skills: skillsPane
                case .plugins: pluginsPane
                case .connectors: connectorsPane
                case .commandLineTools: commandLineToolsPane
                }
            }
            .padding(20)
        }
        .navigationTitle("AI Tools")
        .onAppear(perform: reload)
        .onChange(of: scope) { reload() }
        .onChange(of: app.projects) {
            if case .project(let id) = scope, !app.projects.contains(where: { $0.id == id }) {
                scope = .global
            } else {
                reload()
            }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let skill = pendingDeletion {
                Button("Delete every copy of \(skill.name)", role: .destructive) { delete(skill) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let skill = pendingDeletion {
                Text("Removes \(skill.name) from .claude, .agents and .codex in this scope.")
            }
        }
        .alert("Couldn't update AI Tools", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.purple.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Tools").font(.title2.weight(.semibold))
                    Text("Everything your coding agents can discover in this scope.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .help("Refresh inventory")
                Picker("Scope", selection: $scope) {
                    Label("Global", systemImage: "globe").tag(Scope.global)
                    ForEach(app.projects) { project in
                        Label(project.name, systemImage: "folder").tag(Scope.project(project.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }

            HStack(spacing: 10) {
                stat(title: "Skills", count: snapshot.skills.count,
                     icon: "puzzlepiece.extension.fill", color: .blue, category: .skills)
                stat(title: "Plugins", count: snapshot.plugins.count,
                     icon: "shippingbox.fill", color: .purple, category: .plugins)
                stat(title: "MCP", count: snapshot.connectors.count,
                     icon: "network", color: .teal, category: .connectors)
                stat(title: "CLIs", count: snapshot.commandLineTools.count,
                     icon: "terminal.fill", color: .orange, category: .commandLineTools)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func stat(
        title: String, count: Int, icon: String, color: Color, category item: Category
    ) -> some View {
        let isSelected = category == item
        return Button {
            withAnimation(Motion.state(reduceMotion)) {
                category = item
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(isSelected ? 0.22 : 0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(count)").font(.headline.monospacedDigit())
                    Text(title).font(.caption)
                        .foregroundStyle(isSelected ? color : .secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(color)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .background(isSelected ? color.opacity(0.12) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? color.opacity(0.75) : .clear, lineWidth: 1.25)
        }
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Skills

    private var skillsPane: some View {
        toolSection(title: "Skills", subtitle: scopePath, icon: "puzzlepiece.extension.fill", color: .blue) {
            if snapshot.skills.isEmpty {
                empty("No skills found", icon: "puzzlepiece.extension")
            } else {
                ForEach(Array(snapshot.skills.enumerated()), id: \.element.id) { index, skill in
                    skillRow(skill)
                    if index < snapshot.skills.count - 1 { Divider().padding(.leading, 50) }
                }
            }
            Divider()
            HStack {
                Button { errorMessage = SkillCatalog.askClaudeToAddSkill(in: baseURL) } label: {
                    Label("Add with Claude", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Text("Claude asks what you want before creating files.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
    }

    private func skillRow(_ skill: SkillCatalog.Skill) -> some View {
        HStack(spacing: 12) {
            toolIcon("puzzlepiece.extension.fill", color: .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).fontWeight(.medium)
                if let description = skill.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button { reveal(skill.directory) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show in Finder")
            moveMenu(for: skill)
            Button(role: .destructive) { pendingDeletion = skill } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete every copy")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func moveMenu(for skill: SkillCatalog.Skill) -> some View {
        Menu {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            if home.standardizedFileURL.path != baseURL.standardizedFileURL.path {
                Button("Global") { move(skill, to: home) }
            }
            let destinations = app.projects.filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path != baseURL.standardizedFileURL.path
            }
            if !destinations.isEmpty { Divider() }
            ForEach(destinations) { project in
                Button(project.name) { move(skill, to: URL(fileURLWithPath: project.path)) }
            }
        } label: {
            Image(systemName: "arrow.right.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Move skill")
    }

    // MARK: Plugins

    private var pluginsPane: some View {
        toolSection(title: "Plugins", subtitle: "Installed plugin bundles", icon: "shippingbox.fill", color: .purple) {
            if snapshot.plugins.isEmpty {
                empty("No plugins detected in this scope", icon: "shippingbox")
            } else {
                ForEach(Array(snapshot.plugins.enumerated()), id: \.element.id) { index, plugin in
                    HStack(spacing: 12) {
                        toolIcon("shippingbox.fill", color: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(plugin.name).fontWeight(.medium)
                                providerBadge(plugin.provider)
                                if let version = plugin.version {
                                    Text(version).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            if let description = plugin.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button { reveal(plugin.directory) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show plugin in Finder")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    if index < snapshot.plugins.count - 1 { Divider().padding(.leading, 50) }
                }
            }
        }
    }

    // MARK: MCP

    private var connectorsPane: some View {
        toolSection(title: "MCP Servers", subtitle: "Servers declared in agent configuration", icon: "network", color: .teal) {
            if snapshot.connectors.isEmpty {
                empty("No MCP connectors detected in this scope", icon: "network.slash")
            } else {
                ForEach(Array(snapshot.connectors.enumerated()), id: \.element.id) { index, connector in
                    HStack(spacing: 12) {
                        toolIcon("network", color: .teal)
                        Text(connector.name).fontWeight(.medium)
                        providerBadge(connector.provider)
                        Spacer()
                        Button { reveal(connector.configuration) } label: { Image(systemName: "doc") }
                            .buttonStyle(.borderless).help("Show configuration in Finder")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    if index < snapshot.connectors.count - 1 { Divider().padding(.leading, 50) }
                }
            }
        }
    }


    // MARK: Command-line tools

    private var filteredCommandLineTools: [AgentToolCatalog.CommandLineTool] {
        guard !cliSearch.isEmpty else { return snapshot.commandLineTools }
        return snapshot.commandLineTools.filter {
            $0.name.localizedCaseInsensitiveContains(cliSearch)
                || $0.origin.localizedCaseInsensitiveContains(cliSearch)
        }
    }

    private var commandLineToolsPane: some View {
        toolSection(
            title: "Command-line Tools",
            subtitle: isGlobal ? "Development CLIs installed directly by you" : "Executables installed inside this project",
            icon: "terminal.fill", color: .orange
        ) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name or source", text: $cliSearch)
                    .textFieldStyle(.plain)
                if !cliSearch.isEmpty {
                    Button { cliSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            .padding(12)

            Divider()
            if filteredCommandLineTools.isEmpty {
                empty(cliSearch.isEmpty ? "No command-line tools detected in this scope" : "No CLIs match this search",
                      icon: "terminal")
            } else {
                ForEach(Array(filteredCommandLineTools.enumerated()), id: \.element.id) { index, tool in
                    HStack(spacing: 12) {
                        toolIcon("terminal.fill", color: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).fontWeight(.medium)
                            Text(tool.executable.deletingLastPathComponent().path
                                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(tool.origin)
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: Capsule())
                        Button { reveal(tool.executable) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show executable in Finder")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    if index < filteredCommandLineTools.count - 1 { Divider().padding(.leading, 50) }
                }
            }
        }
    }

    // MARK: Shared UI/actions

    private func toolSection<Content: View>(
        title: String, subtitle: String, icon: String, color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                toolIcon(icon, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(14)
            Divider()
            content()
        }
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5))
    }

    private func toolIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func providerBadge(_ provider: AgentToolCatalog.Provider) -> some View {
        switch provider {
        case .codex:
            brandBadge("Codex", asset: "CodexLogo", foreground: .white, background: .black,
                       border: .white.opacity(0.18))
        case .claude:
            brandBadge("Claude", asset: "ClaudeLogo",
                       foreground: Color(red: 1.0, green: 0.66, blue: 0.44),
                       background: Color(red: 0.30, green: 0.13, blue: 0.07),
                       border: Color(red: 0.78, green: 0.34, blue: 0.18).opacity(0.45))
        case .project:
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 9, weight: .semibold))
                Text("Project")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
    }

    private func brandBadge(
        _ title: String, asset: String, foreground: Color, background: Color, border: Color
    ) -> some View {
        HStack(spacing: 4) {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 10, height: 10)
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(background, in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 0.5))
    }

    private func empty(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(26)
    }

    private var baseURL: URL {
        switch scope {
        case .global: return URL(fileURLWithPath: NSHomeDirectory())
        case .project(let id):
            return app.projects.first(where: { $0.id == id })
                .map { URL(fileURLWithPath: $0.path) }
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    private var isGlobal: Bool {
        if case .global = scope { return true }
        return false
    }

    private var scopePath: String {
        baseURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func reload() {
        snapshot = AgentToolCatalog.snapshot(at: baseURL, global: isGlobal)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func move(_ skill: SkillCatalog.Skill, to destination: URL) {
        do {
            try SkillCatalog.moveAllCopies(named: skill.name, from: baseURL, to: destination)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ skill: SkillCatalog.Skill) {
        defer { pendingDeletion = nil }
        do {
            try SkillCatalog.removeAllCopies(named: skill.name, at: baseURL)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
