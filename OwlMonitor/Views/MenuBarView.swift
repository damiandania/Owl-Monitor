import SwiftUI
import AppKit

/// Compact panel shown from the menu-bar icon: one collapsible section per added project (expand to
/// start/stop its dev / worker / build / preview controls), any external dev servers, and a live
/// system snapshot — without opening the main window.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Per-project expand override; absent → defaults to expanded when the project has something live.
    @State private var expandedOverride: [Project.ID: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Owl Monitor", systemImage: "waveform.path.ecg")
                .font(.headline)

            Divider()
            serversSection

            Divider()
            systemSection

            Divider()
            HStack {
                Button("Open Window") { app.bringMainWindowToFront() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// One collapsible section per project (every added project, not just the running ones): the
    /// header shows the project's aggregate status; expanding reveals its run-controls (dev / worker /
    /// build / preview — straight from `AppState.runControls`) to start/stop. Dev servers running
    /// OUTSIDE the app are listed below, unsupervised.
    @ViewBuilder private var serversSection: some View {
        let external = app.systemSampler.processes.filter { $0.isExternalDev }

        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                if app.projects.isEmpty {
                    Text("No projects yet — add one in the window.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(app.projects.sorted { $0.name < $1.name }) { projectDisclosure($0) }
                }
                if !external.isEmpty {
                    Divider()
                    ForEach(external) { externalRow($0) }
                }
            }
        }
    }

    /// A collapsible project: header (chevron · status dot · name · aggregate state) and, when
    /// expanded, an indented run-control row per startable/running process.
    @ViewBuilder private func projectDisclosure(_ project: Project) -> some View {
        let controls = app.runControls(for: project)
        let live = controls.contains { $0.isLive }
        let isOpen = expandedOverride[project.id] ?? live
        let agg = aggregate(controls)
        let dev = controls.first { $0.kind == "dev" }

        VStack(alignment: .leading, spacing: 6) {
            ProjectHeaderRow(
                project: project, isOpen: isOpen, aggColor: agg.color, aggLabel: agg.label, dev: dev,
                onToggleExpand: { expandedOverride[project.id] = !isOpen },
                onDev: { expandedOverride[project.id] = false; dev?.onToggle() })

            if isOpen {
                // Nest the controls in a faint rounded panel, indented under the name, so the child
                // list reads as a group and doesn't blend into the flat parent rows.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controls) { ControlRowView(control: $0) }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 18)
                .padding(.top, 1)
                // Unfolds down out of its header rather than blinking into place.
                .transition(.rise(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.state(reduceMotion), value: isOpen)
    }

    /// Aggregate status across a project's controls: failed (red) ▸ starting (orange) ▸ running
    /// (green) ▸ idle (gray) — drives the collapsed header's dot + label.
    private func aggregate(_ controls: [RunControl]) -> (color: Color, label: String) {
        if controls.contains(where: { $0.status.error != nil }) { return (.red, "Failed") }
        if controls.contains(where: { $0.status.isInProgress }) { return (.orange, "Starting") }
        if controls.contains(where: { $0.status.showsStop })    { return (.green, "Running") }
        return (.secondary, "Idle")
    }

    private func externalRow(_ row: ProcessRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xserve").font(.caption).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.subheadline.weight(.semibold)).foregroundStyle(.indigo).lineLimit(1)
                Text("external · not supervised").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var systemSection: some View {
        let s = app.systemSampler
        return VStack(alignment: .leading, spacing: 6) {
            meter("CPU", value: s.systemCPU, text: String(format: "%.0f%%", s.systemCPU))
            meter("Memory", value: s.systemMemPercent, text: String(format: "%.0f%%", s.systemMemPercent))
        }
    }

    private func meter(_ title: String, value: Double, text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 56, alignment: .leading)
            ProgressView(value: min(max(value, 0), 100), total: 100)
            Text(text).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    fileprivate static func uptime(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// A collapsible project's header row: chevron · status dot · name, plus a dev play/stop button on
/// the right. The PLAY button is revealed on hover (so idle projects stay clean); a STOP button
/// (running/starting) is always visible. Shown only while collapsed — when expanded, the Dev row
/// inside already carries this control. Local hover @State means each row tracks its own hover.
private struct ProjectHeaderRow: View {
    let project: Project
    let isOpen: Bool
    let aggColor: Color
    let aggLabel: String
    let dev: RunControl?
    let onToggleExpand: () -> Void
    let onDev: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggleExpand) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    StatusDot(color: aggColor, accessibilityLabel: aggLabel)
                    Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let dev, !isOpen {
                let showsStop = dev.status.showsStop
                Button(action: onDev) {
                    Image(systemName: showsStop ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help((showsStop ? "Stop " : "Start ") + project.name)
                .opacity(showsStop || hovering ? 1 : 0)       // play hides until hover; stop stays
                .allowsHitTesting(showsStop || hovering)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// One run-control inside an expanded project: icon · title · status · uptime · play/stop. The PLAY
/// button is revealed on hover; a STOP button is always visible.
private struct ControlRowView: View {
    let control: RunControl
    @State private var hovering = false

    var body: some View {
        let showsStop = control.status.showsStop
        HStack(spacing: 6) {
            Image(systemName: control.icon).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(control.title).font(.subheadline).lineLimit(1)
            Text(LocalizedStringKey(control.status.label.isEmpty ? "Idle" : control.status.label))
                .font(.caption.weight(.medium)).foregroundStyle(control.status.color).lineLimit(1)
            if let started = control.startedAt, showsStop {
                Text("· \(MenuBarView.uptime(since: started))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: control.onToggle) {
                Image(systemName: showsStop ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help((showsStop ? "Stop " : "Start ") + control.title.lowercased())
            .opacity(showsStop || hovering ? 1 : 0)       // play hides until hover; stop stays
            .allowsHitTesting(showsStop || hovering)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
