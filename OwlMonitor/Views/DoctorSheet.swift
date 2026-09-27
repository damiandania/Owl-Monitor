import SwiftUI
import AppKit

/// The "Doctor" window. Sidebar = the three analyses; detail = an Apple-style list of processes to
/// close (Heavy / Memory) or a text diagnosis (Owl Monitor). The big circular Analyze button sits in
/// the top-right corner and flips to a red Stop while running. Nothing runs until you press it.
struct DoctorSheet: View {
    @Environment(AppState.self) private var app
    @State private var section: Section = .heavy
    /// Which project the "Project" tab diagnoses. nil = follow the sidebar selection; set by the
    /// in-tab picker so the Doctor window can target any project on its own.
    @State private var projectID: Project.ID?

    enum Section: String, CaseIterable, Identifiable {
        case heavy, project, liveScan, memory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .heavy: return "Heavy Processes"
            case .project: return "Project"
            case .liveScan: return "Live Scan"
            case .memory: return "Memory & RAM"
            }
        }
        var icon: String {
            switch self {
            case .heavy: return "gauge.with.dots.needle.67percent"
            case .project: return "ladybug.fill"
            case .liveScan: return "waveform.path.ecg"
            case .memory: return "memorychip.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { s in
                    SectionRow(section: s, busy: busy(s), hasResult: hasResult(s),
                               stop: { stop(s) }, reanalyze: { start(s) })
                        .tag(s)
                }
            }
            .navigationTitle("Doctor")
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail.navigationTitle(section.title)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let b = busy(section), r = hasResult(section)
                // The button itself is the coloured circle (prominent + .circle shape) so there's no
                // white toolbar bezel/glass pill around it — drawing our own circle left the system
                // background showing as a white halo.
                Button { b ? stop(section) : start(section) } label: {
                    Image(systemName: b ? "stop.fill" : (r ? "arrow.clockwise" : "play.fill"))
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(b ? .red : .accentColor)
                .help(b ? "Stop analysis" : (r ? "Re-analyze" : "Analyze"))
            }
        }
        .frame(minWidth: 820, minHeight: 580)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .heavy:
            AdviceList(advice: app.advice, busy: app.isAdvising,
                       idle: "Analyze the machine's heaviest processes and what's safe to close.",
                       freeAllTitle: nil)
        case .project:
            ProjectDiagnosisDetail(projectID: $projectID)
        case .liveScan:
            LiveScanDetail()
        case .memory:
            AdviceList(advice: app.memoryAdvice, busy: app.isGeneratingMemory,
                       idle: "Find the biggest memory hogs and what to close to free RAM.",
                       freeAllTitle: "Free memory")
        }
    }

    // Per-section analyze state/actions (so the sidebar shows each tab's progress, not just the
    // selected one).
    private func busy(_ s: Section) -> Bool {
        switch s {
        case .heavy: return app.isAdvising
        case .project: return app.isDiagnosingProject
        case .liveScan: return app.isLiveScanning
        case .memory: return app.isGeneratingMemory
        }
    }
    private func hasResult(_ s: Section) -> Bool {
        switch s {
        case .heavy: return app.advice != nil
        case .project: return app.projectDiagnosis != nil
        case .liveScan: return app.liveScanReport != nil
        case .memory: return app.memoryAdvice != nil
        }
    }
    private func start(_ s: Section) {
        switch s {
        case .heavy: app.generateAdvice()
        case .project: app.diagnoseProject(projectID: projectID ?? app.selectedProjectID)
        case .liveScan: app.startLiveScan()
        case .memory: app.generateMemory()
        }
    }
    private func stop(_ s: Section) {
        switch s {
        case .heavy: app.stopAdvice()
        case .project: app.stopProjectDiagnosis()
        case .liveScan: app.stopLiveScan()
        case .memory: app.stopMemory()
        }
    }
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// A Doctor sidebar row: title + a status accessory on the right so you can see which tab is
/// working even when it isn't selected — a spinner while analyzing (hover → red Stop), or a green
/// check once done (hover → Reset).
private struct SectionRow: View {
    let section: DoctorSheet.Section
    let busy: Bool
    let hasResult: Bool
    let stop: () -> Void
    let reanalyze: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.icon)
            Spacer()
            status
                .frame(width: 22, height: 22)
                .onHover { hovering = $0 }
        }
    }

    @ViewBuilder private var status: some View {
        if busy {
            if hovering {
                Button(action: stop) { badge("stop.fill", .red) }.buttonStyle(.plain).help("Stop")
            } else {
                ProgressView().controlSize(.small)
            }
        } else if hasResult {
            if hovering {
                Button(action: reanalyze) { badge("arrow.clockwise", .accentColor) }
                    .buttonStyle(.plain).help("Re-analyze")
            } else {
                badge("checkmark", .green)
            }
        }
    }

    /// A small colored circle with a white glyph. `.drawingGroup()` rasterises it into an opaque
    /// bitmap so the macOS selection vibrancy can't darken the colour on the blue selected row —
    /// the same fix as the sidebar's running dot. No white ring/background.
    private func badge(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color))
            .drawingGroup()
    }
}

// MARK: - Advice list (Heavy Processes & Memory) — Apple-style grouped rows

private struct AdviceList: View {
    @Environment(AppState.self) private var app
    let advice: ResourceAdvisor.Advice?
    let busy: Bool
    let idle: String
    /// When set, shows a prominent button that closes every recommended process at once.
    let freeAllTitle: String?

    @State private var pendingClose: ResourceAdvisor.Recommendation?
    @State private var confirmAll = false

    private var closeable: [ResourceAdvisor.Recommendation] {
        (advice?.recommendations ?? []).filter { $0.action == .closeProcess || $0.action == .stopDevServer }
    }

    var body: some View {
        Group {
            if busy {
                Loading("Asking Claude…")
            } else if let advice {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !advice.summary.isEmpty {
                            Text(advice.summary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let freeAllTitle, !closeable.isEmpty {
                            Button { confirmAll = true } label: {
                                Label(freeAllTitle, systemImage: "sparkles").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        if closeable.isEmpty {
                            Text("Nothing recommended to close — looks healthy.").foregroundStyle(.secondary)
                        } else {
                            list
                        }
                    }
                    .padding()
                }
                CostFooter(isError: advice.isError, cost: advice.costUSD)
            } else {
                Idle(idle)
            }
        }
        .confirmationDialog(
            pendingClose.map { "Close \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible
        ) {
            if let rec = pendingClose {
                Button("Close \(rec.name) (pid \(rec.id))", role: .destructive) { app.apply(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rec = pendingClose { Text(rec.reason) }
        }
        .confirmationDialog(
            "Close \(closeable.count) process\(closeable.count == 1 ? "" : "es") to free memory?",
            isPresented: $confirmAll, titleVisibility: .visible
        ) {
            Button("Close \(closeable.count) and free memory", role: .destructive) { app.applyAll(closeable) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(closeable.map(\.name).joined(separator: ", "))
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(closeable.enumerated()), id: \.element.id) { i, rec in
                row(rec)
                if i < closeable.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ rec: ResourceAdvisor.Recommendation) -> some View {
        HStack(spacing: 12) {
            StatusDot(color: rec.severity.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.name).fontWeight(.medium).lineLimit(1)
                    if rec.managed {
                        Text("managed").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                }
                Text(rec.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                if rec.action == .stopDevServer {
                    Button { app.apply(rec) } label: { Label("Stop dev server", systemImage: "stop.fill") }
                } else {
                    Button(role: .destructive) { pendingClose = rec } label: {
                        Label("Close \(rec.name)", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().strokeBorder(.tertiary))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

}

// MARK: - Project failure diagnosis (text report on the selected project)

private struct ProjectDiagnosisDetail: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// nil = follow the sidebar selection (the picker shows/overrides it).
    @Binding var projectID: Project.ID?

    private var effectiveID: Project.ID? { projectID ?? app.selectedProjectID }
    private var project: Project? { app.projects.first { $0.id == effectiveID } }

    /// Which screen is up. The cross-fade keys on this — not on the content — so text changing
    /// WITHIN a screen (the idle prompt naming another project) swaps in place instead of fading.
    private var screen: String {
        if app.isDiagnosingProject { return "loading" }
        return app.projectDiagnosis == nil ? "idle" : "report"
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider()
            ZStack {
                content
                    .id(screen)
                    .transition(.rise(reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.region(reduceMotion), value: screen)
        }
    }

    /// Pick which project to diagnose — defaults to the sidebar selection, but the Doctor window can
    /// target any project on its own. (Press Analyze in the toolbar to run it.)
    private var picker: some View {
        HStack(spacing: 8) {
            Text("Project").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { effectiveID }, set: { projectID = $0 })) {
                ForEach(app.projects) { p in Text(p.name).tag(p.id as Project.ID?) }
            }
            .labelsHidden().fixedSize()
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if app.isDiagnosingProject {
            Loading("Asking Claude…")
        } else if let report = app.projectDiagnosis {
            ReportPane(report: report)
        } else if let project {
            Idle("Diagnose why \(project.name)'s server or build failed — reads its logs and config (read-only). Press Analyze.")
        } else {
            Idle("Add a project first, then pick it above to diagnose why its server or build failed.")
        }
    }
}

// MARK: - Live Scan (timed observation → copyable report)

/// Watches Owl Monitor + the machine for a chosen window (progress bar), then shows Claude's
/// structured, copyable report. Idle state offers the observation duration; while observing it shows
/// a determinate progress bar; while Claude reasons it shows a spinner.
private struct LiveScanDetail: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which of the four screens is up — the cross-fade's key. Keying on the screen (not the
    /// content) keeps the observing view's per-second progress updating in place, not re-fading.
    private var screen: String {
        switch app.liveScan.phase {
        case .observing: "observing"
        case .analyzing: "analyzing"
        case .idle: app.liveScanReport == nil ? "idle" : "result"
        }
    }

    var body: some View {
        ZStack {
            content
                .id(screen)
                .transition(.rise(reduceMotion: reduceMotion))
        }
        .animation(Motion.region(reduceMotion), value: screen)
    }

    @ViewBuilder private var content: some View {
        switch app.liveScan.phase {
        case .observing: observing
        case .analyzing: Loading("Analyzing with Claude…")
        case .idle:
            if let report = app.liveScanReport { result(report) } else { idle }
        }
    }

    private var observing: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg").font(.largeTitle)
                .foregroundStyle(.tint).symbolEffect(.pulse)
            Text("Observing Owl Monitor & the machine…").font(.headline)
            ProgressView(value: app.liveScan.progress).frame(maxWidth: 320)
            Text("\(app.liveScan.elapsed)s / \(app.liveScan.duration)s — watching processes, activity and internal errors")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var idle: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.secondary)
            Text("Watch Owl Monitor live for a couple of minutes, then get a copyable report: what "
                 + "every process is and who it belongs to, the activity, any errors or bugs, and "
                 + "improvement points. Read-only.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            Picker("Observe for", selection: durationBinding) {
                Text("1 min").tag(60)
                Text("2 min").tag(120)
                Text("5 min").tag(300)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            Text("Press ▶ to start").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var durationBinding: Binding<Int> {
        Binding(get: { app.liveScan.duration }, set: { app.liveScan.duration = $0 })
    }

    private func result(_ report: ClaudeRunner.Report) -> some View {
        ReportPane(report: report)
    }
}

// MARK: - shared

/// A finished Claude report: full-height scrollable markdown + a "Copy report" button + the
/// cost/error footer. Shared by the Doctor's Project and Live Scan tabs so both render — and copy —
/// identically (and neither gets visually clipped at the bottom).
private struct ReportPane: View {
    let report: ClaudeRunner.Report
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(DoctorSheet.markdown(report.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy report",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .animation(Motion.state(reduceMotion), value: copied)
                Spacer()
            }
            .padding(.horizontal).padding(.top, 6)
            .onChange(of: report.text) { copied = false }
            CostFooter(isError: report.isError, cost: report.costUSD)
        }
    }
}

private struct Idle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct Loading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(spacing: 12) { ProgressView(); Text(text).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CostFooter: View {
    let isError: Bool
    let cost: Double?
    var body: some View {
        if isError || cost != nil {
            HStack {
                if isError {
                    Label("claude reported an error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let cost { Text(String(format: "claude · $%.4f", cost)).foregroundStyle(.secondary) }
            }
            .font(.caption).padding(.horizontal).padding(.bottom, 8)
        }
    }
}
