import SwiftUI
import AppKit

extension Color {
    static let claudeCoral = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

extension NSScreen {
    /// The screen that carries the notch — the bar is pinned here (not to the focus-following `.main`),
    /// so it stays put beside the notch instead of following focus to an external display. Detected via
    /// `safeAreaInsets.top` (the physical notch's inset), which is STABLE — unlike `auxiliaryTopLeftArea`,
    /// which briefly goes nil during Space/display transitions and would otherwise make the bar jump.
    static var notched: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? .main ?? screens.first
    }

    /// True for the built-in notch display even mid-transition (when the auxiliary areas read nil).
    var hasNotch: Bool { safeAreaInsets.top > 0 }
}

enum QuotaSource { case claude, gpt }

/// The current ChatGPT menu-bar glyph, supplied by the installed ChatGPT app. GPT quota probing
/// already depends on this app's bundled Codex CLI, so this keeps the HUD aligned with its live icon.
private enum ChatGPTBrand {
    static let menuBarGlyph = NSImage(contentsOfFile: "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png")
        ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ChatGPT")!
}

/// The always-visible readout on the RIGHT side of the notch bar. Clicking it alternates between
/// Claude's 5-hour / 7-day remaining quota and the signed-in GPT (Codex) remaining quota. The black background itself is
/// drawn by `QuotaHUDController`'s container, which continues seamlessly beneath the physical notch.
struct QuotaHUDView: View {
    var claudeQuota: ClaudeQuotaMonitor
    var gptQuota: CodexQuotaMonitor
    var source: QuotaSource
    var appState: AppState
    var barHeight: CGFloat
    var onContentChange: () -> Void
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            switch source {
            case .claude:
                Image("ClaudeLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 13, height: 13).foregroundStyle(Color.claudeCoral)
                if claudeQuota.status == .ok {
                    let numberColor: Color = claudeQuota.isStale ? .claudeCoral.opacity(0.5) : .claudeCoral
                    if let five = claudeQuota.fiveHour { claudeMetric(five, numberColor) }
                    if let seven = claudeQuota.sevenDay { claudeMetric(seven, numberColor) }
                } else {
                    statusBadge(claudeQuota.status, cli: "Claude",
                                reauth: "run `claude` in a terminal and sign in")
                }
            case .gpt:
                Image(nsImage: ChatGPTBrand.menuBarGlyph)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 13, height: 13)
                if gptQuota.status == .ok {
                    if let window = gptQuota.primary ?? gptQuota.secondary { gptMetric(window) }
                    if !gptQuota.hasData { Text("—").foregroundStyle(.white.opacity(0.6)) }
                } else {
                    statusBadge(gptQuota.status, cli: "Codex", reauth: "run `codex login` in a terminal")
                }
            }
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .imageScale(.medium)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: barHeight)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onChange(of: claudeQuota.fiveHour == nil) { _, _ in onContentChange() }
        .onChange(of: claudeQuota.sevenDay == nil) { _, _ in onContentChange() }
        .onChange(of: claudeQuota.status) { _, _ in onContentChange() }
        .onChange(of: gptQuota.hasData) { _, _ in onContentChange() }
        .onChange(of: gptQuota.status) { _, _ in onContentChange() }
    }

    /// Shown INSTEAD OF the percentages when a probe can't get a real reading — a frozen old value
    /// would otherwise look like a fresh, reassuring "usage is low" signal. Each failure mode gets
    /// its own glyph + tooltip so the badge tells the user what to DO: `?` = the CLI isn't installed;
    /// a person-with-warning = the login/session expired (re-auth); a triangle = ran but returned
    /// nothing (transient — retrying). `cli` names the tool; `reauth` is the sign-in hint.
    @ViewBuilder private func statusBadge(_ status: QuotaStatus, cli: String, reauth: String) -> some View {
        switch status {
        case .ok:
            EmptyView()
        case .notInstalled:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.white.opacity(0.6))
                .help("\(cli) CLI not found — install the Codex desktop app to show usage")
        case .signedOut:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.yellow)
                .help("\(cli) usage unavailable — the session expired. \(reauth.prefix(1).uppercased() + reauth.dropFirst()) to restore it.")
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help("Couldn't read \(cli) usage — no data returned (e.g. several Claude Code sessions competing). Retrying.")
        }
    }

    private func claudeMetric(_ usedPercent: Int, _ color: Color) -> some View {
        Text("\(remainingPercent(usedPercent))%")
        .foregroundStyle(color)
        .help(claudeQuota.isStale
              ? "Claude quota — no recent update; run a Claude session to refresh"
              : "Claude quota remaining · first value = 5-hour window · second value = 7-day window")
    }

    private func gptMetric(_ window: CodexQuotaMonitor.Window) -> some View {
        Text("\(remainingPercent(window.usedPercent))%")
        .foregroundStyle(gptQuota.isStale ? .white.opacity(0.5) : .white)
        .help(gptQuota.isStale
              ? "GPT quota — no recent update; make sure Codex is installed and signed in"
              : "GPT quota remaining")
    }

    private func remainingPercent(_ usedPercent: Int) -> Int {
        max(0, min(100, 100 - usedPercent))
    }

}

private enum NotchStatus: Equatable {
    case online, serving, launching, building, stopped, warning

    var color: Color {
        switch self {
        case .online: .green
        case .serving: .previewMagenta   // production build being served — see RunStatus.serving
        case .launching: .orange
        case .building: .blue
        case .stopped: .red
        case .warning: .yellow
        }
    }

    var pulses: Bool { self == .launching || self == .building }

    var title: String {
        switch self {
        case .online: "Online"
        case .serving: "Serving"
        case .launching: "Starting"
        case .building: "Building"
        case .stopped: "Stopped or failed"
        case .warning: "Needs attention"
        }
    }
}

private struct NotchStatusItem: Identifiable {
    let project: Project
    let status: NotchStatus
    let detail: String

    var id: Project.ID { project.id }
}

/// Status icons on the left of the notch. Each project appears only once, using the most important
/// current state: build (blue) > serving a production build (magenta) > online (green) >
/// launching (orange) > warning > stopped (red).
/// A project remains green when any
/// one of its managed processes is alive, even if a separate preview/build was stopped earlier.
private struct NotchStatusStrip: View {
    let appState: AppState
    let barHeight: CGFloat
    let onZoneHover: (Bool) -> Void

    private static let maximumVisibleProjects = 8
    private static let minimumWidth: CGFloat = 130
    private static let iconSlotWidth: CGFloat = 20

    var body: some View {
        let allItems = Self.items(for: appState)
        let visibleItems = Array(allItems.prefix(Self.maximumVisibleProjects))
        let hiddenCount = allItems.count - visibleItems.count

        HStack(spacing: 4) {
            if appState.systemUnderPressure { pressureIcon }
            ForEach(visibleItems) { item in
                NotchProjectStatusIcon(item: item)
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(minWidth: 16)
                    .frame(height: 16)
                    .help("\(hiddenCount) more monitored project\(hiddenCount == 1 ? "" : "s")")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.horizontal, 9)
        .contentShape(Rectangle())
        .onHover { onZoneHover($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project status")
    }

    private var pressureIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.yellow)
            .frame(width: 16, height: 16)
            .help("Machine under pressure")
            .accessibilityLabel("Machine under pressure")
    }

    static func preferredWidth(for appState: AppState) -> CGFloat {
        let projectCount = min(items(for: appState).count, maximumVisibleProjects)
        let overflow = items(for: appState).count > maximumVisibleProjects ? 1 : 0
        let count = projectCount + overflow + (appState.systemUnderPressure ? 1 : 0)
        // The left stage always begins as wide as the quota stage, then expands only when the
        // project icons no longer fit comfortably at their compact size.
        return max(minimumWidth, CGFloat(count) * iconSlotWidth + CGFloat(max(0, count - 1)) * 4 + 18)
    }

    static func items(for appState: AppState) -> [NotchStatusItem] {
        appState.projects.compactMap { project in
            guard let status = status(for: project, appState: appState) else { return nil }
            return NotchStatusItem(project: project, status: status.status, detail: status.detail)
        }
    }

    private static func status(for project: Project, appState: AppState) -> (status: NotchStatus, detail: String)? {
        let sessions = [appState.sessions[project.id], appState.previews[project.id]].compactMap { $0 }
        let hasServerFailure = sessions.contains { session in
            if case .failed = session.state { return true }
            if case .stopped = session.state { return true }
            return false
        }
        let hasWarning = sessions.contains { session in
            if case .degraded = session.state { return true }
            return false
        }
        let isLaunching = sessions.contains { session in
            if case .launching = session.state { return true }
            if case .recycling = session.state { return true }
            return false
        }
        let isOnline = sessions.contains { session in
            if case .running = session.state { return true }
            return false
        }
        let isPreviewOnline: Bool = {
            guard let preview = appState.previews[project.id] else { return false }
            if case .running = preview.state { return true }
            return false
        }()
        let worker = appState.workers[project.id]
        let build = appState.builds[project.id]

        if build?.isRunning == true { return (.building, "Build in progress") }
        // A live preview is serving the production BUILD, not dev sources — checked before the
        // generic "online" so it reads magenta rather than the dev server's green. Dev and preview
        // are mutually exclusive per project (see AppState.stopSiblings), so this never masks a
        // running dev server.
        if isPreviewOnline { return (.serving, "Serving the production build") }
        if isOnline || worker?.isRunning == true { return (.online, "Server is online") }
        if isLaunching { return (.launching, "Server is starting") }
        if hasWarning { return (.warning, "Server health needs attention") }
        if hasServerFailure || worker?.didCrash == true || (build?.result ?? 0) != 0 {
            return (.stopped, "Stopped or failed")
        }
        // A manually stopped worker has an exit code but is not a crash; it is still useful to surface it.
        if worker?.lastExitCode != nil { return (.stopped, "Worker stopped") }
        return nil
    }
}

private struct NotchProjectStatusIcon: View {
    let item: NotchStatusItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if item.status.pulses && !reduceMotion {
                Circle()
                    .stroke(item.status.color, lineWidth: 1.5)
                    .scaleEffect(isPulsing ? 1.65 : 1)
                    .opacity(isPulsing ? 0 : 0.72)
                    .animation(.easeOut(duration: item.status == .building ? 0.72 : 0.95)
                        .repeatForever(autoreverses: true), value: isPulsing)
            }
            Circle().fill(.black)
            // Cross-fade the ring between states (e.g. orange → magenta when a preview comes up).
            // A colour fade isn't motion, so it stays on under Reduce Motion.
            Circle().stroke(item.status.color, lineWidth: 1.75)
                .animation(Motion.state(reduceMotion), value: item.status)
            ProjectIconView(project: item.project, size: 10)
                .clipShape(Circle())
        }
        .frame(width: 16, height: 16)
        .help("\(item.project.name): \(item.detail)")
        .accessibilityLabel("\(item.project.name): \(item.detail)")
        .onAppear(perform: syncPulse)
        .onChange(of: item.status) { _, _ in syncPulse() }
        .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        isPulsing = item.status.pulses && !reduceMotion
    }
}

/// Owns the notch bar: ONE borderless panel spanning the project-state strip, notch, and quota
/// readout. The physical notch covers its middle, making the overlay read as one continuous shape.
/// Hovering the project-state end opens the controls popover; the quota end is click-only.
@MainActor
final class QuotaHUDController {
    private let panel: NSPanel
    /// The one black strip: rounded at BOTH outer-bottom corners, square across the notch.
    private let container: NSView
    private let barMask = CAShapeLayer()
    private let statusHosting: NSHostingView<NotchStatusStrip>
    private let hosting: NSHostingView<QuotaHUDView>
    private let popover: NSPopover
    private let barHeight: CGFloat
    private let appState: AppState
    private let claudeQuota: ClaudeQuotaMonitor
    private let gptQuota: CodexQuotaMonitor
    private var quotaSource: QuotaSource = .claude

    private var hudHovered = false
    private var menuHovered = false
    private var closeWork: DispatchWorkItem?
    private var statusTimer: Timer?
    private var statusWidth: CGFloat = 130
    private var didInstallStatusStrip = false
    private static let quotaWidth: CGFloat = 130

    init(claudeQuota: ClaudeQuotaMonitor, gptQuota: CodexQuotaMonitor, appState: AppState) {
        self.appState = appState
        self.claudeQuota = claudeQuota
        self.gptQuota = gptQuota
        barHeight = NSScreen.notched?.auxiliaryTopRightArea?.height ?? Self.menuBarHeight()

        popover = NSPopover()
        popover.behavior = .transient

        hosting = NSHostingView(rootView: QuotaHUDView(claudeQuota: claudeQuota, gptQuota: gptQuota,
                                                       source: .claude, appState: appState,
                                                       barHeight: barHeight,
                                                       onContentChange: {}, onToggle: {}))
        statusHosting = NSHostingView(rootView: NotchStatusStrip(appState: appState, barHeight: barHeight,
                                                                 onZoneHover: { _ in }))

        container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        container.layer?.mask = barMask         // custom notch silhouette (concave top, convex bottom)

        container.addSubview(statusHosting)
        container.addSubview(hosting)

        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Above the fullscreen shield so it stays visible over fullscreen apps (`.statusBar` sits
        // BELOW fullscreen content); `.fullScreenAuxiliary` + `.canJoinAllSpaces` put it on every
        // Space, so it's a standalone overlay, not tied to the (hidden-in-fullscreen) menu bar.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = container
        reposition()
        panel.orderFrontRegardless()

        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environment(appState).environment(\.locale, appState.uiLocale)
                .onHover { [weak self] in self?.menuHover($0) })

        updateQuotaView()
        updateStatusStrip()
        // The SwiftUI strip observes individual state changes. This light poll only adjusts its AppKit
        // host width as projects appear/disappear, so icons can grow out from the notch without jumps.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusStrip() }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func updateQuotaView() {
        hosting.rootView = QuotaHUDView(claudeQuota: claudeQuota, gptQuota: gptQuota,
                                        source: quotaSource, appState: appState, barHeight: barHeight,
                                        onContentChange: { [weak self] in
                                            DispatchQueue.main.async { self?.reposition() }
                                        }, onToggle: { [weak self] in self?.toggleQuotaSource() })
    }

    private func toggleQuotaSource() {
        quotaSource = quotaSource == .claude ? .gpt : .claude
        if quotaSource == .gpt { gptQuota.activate() }
        updateQuotaView()
    }

    private func updateStatusStrip() {
        if !didInstallStatusStrip {
            statusHosting.rootView = NotchStatusStrip(appState: appState, barHeight: barHeight,
                                                       onZoneHover: { [weak self] in self?.zoneHover($0) })
            didInstallStatusStrip = true
        }
        let updatedWidth = NotchStatusStrip.preferredWidth(for: appState)
        guard abs(updatedWidth - statusWidth) > 0.5 else { return }
        statusWidth = updatedWidth
        reposition()
    }

    // MARK: - Hover / popover

    private func zoneHover(_ hovering: Bool) {
        hudHovered = hovering
        if hovering { openMenu() } else { scheduleClose() }
    }

    private func menuHover(_ hovering: Bool) {
        menuHovered = hovering
        if hovering { closeWork?.cancel() } else { scheduleClose() }
    }

    private func openMenu() {
        closeWork?.cancel()
        guard !popover.isShown else { return }
        popover.show(relativeTo: statusHosting.bounds, of: statusHosting, preferredEdge: .minY)
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hudHovered, !self.menuHovered, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Geometry

    /// One frame for the whole bar: the project-state strip hugs the notch's left side and quota
    /// readout the right. The physical notch covers the middle of the black container, so it remains
    /// one continuous shape. Falls back to a compact bar in the top-right corner without a notch.
    @objc private func reposition() {
        guard let screen = NSScreen.notched else { return }
        let leftWidth = statusWidth
        let rightWidth = Self.quotaWidth
        let frame: NSRect
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let h = left.height
            frame = NSRect(x: left.maxX - leftWidth, y: left.minY,
                           width: leftWidth + (right.minX - left.maxX) + rightWidth, height: h)
        } else if screen.hasNotch {
            // Notch display mid-transition: the auxiliary areas momentarily read nil. Keep the last
            // good frame instead of jumping to a corner — the bar must stay static behind the camera.
            return
        } else {
            let h = Self.menuBarHeight(on: screen)
            frame = NSRect(x: screen.frame.maxX - leftWidth - rightWidth - 8, y: screen.frame.maxY - h,
                           width: leftWidth + rightWidth, height: h)
        }
        panel.setFrame(frame, display: true)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = frame.height
        container.frame = NSRect(origin: .zero, size: frame.size)
        barMask.frame = CGRect(origin: .zero, size: frame.size)
        barMask.path = Self.notchPath(width: frame.width, height: h,
                                      topRadius: min(h * 0.28, 12), bottomRadius: h * 0.32)
        statusHosting.frame = NSRect(x: 0, y: 0, width: leftWidth, height: h)
        hosting.frame = NSRect(x: frame.width - rightWidth, y: 0, width: rightWidth, height: h)
        CATransaction.commit()
    }

    /// A notch silhouette in the layer's (y-up) coordinate space: the top-outer corners flare out
    /// CONCAVELY so the bar melts into the top bezel (no hard 90° corner), while the bottom-outer
    /// corners round CONVEXLY into the menu bar. `tR` = top concave radius, `bR` = bottom convex radius.
    nonisolated private static func notchPath(width W: CGFloat, height H: CGFloat,
                                              topRadius tR: CGFloat, bottomRadius bR: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: H))                                              // top-left @ screen top
        p.addQuadCurve(to: CGPoint(x: tR, y: H - tR), control: CGPoint(x: tR, y: H)) // concave top-left
        p.addLine(to: CGPoint(x: tR, y: bR))                                         // down left side
        p.addQuadCurve(to: CGPoint(x: tR + bR, y: 0), control: CGPoint(x: tR, y: 0)) // convex bottom-left
        p.addLine(to: CGPoint(x: W - tR - bR, y: 0))                                 // bottom edge
        p.addQuadCurve(to: CGPoint(x: W - tR, y: bR), control: CGPoint(x: W - tR, y: 0)) // convex bottom-right
        p.addLine(to: CGPoint(x: W - tR, y: H - tR))                                 // up right side
        p.addQuadCurve(to: CGPoint(x: W, y: H), control: CGPoint(x: W - tR, y: H))   // concave top-right
        p.closeSubpath()                                                             // top edge back to start
        return p
    }

    private static func menuBarHeight(on screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen else { return 24 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }
}
