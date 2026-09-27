import SwiftUI

/// Activity-Monitor-style list of the heaviest system processes. A custom row list (not the
/// native `Table`) so it sits flush on the card with hover highlighting, tinted dev-server rows
/// and right-aligned monospaced metrics.
struct ProcessTableView: View {
    @Environment(AppState.self) private var app
    let sampler: SystemSampler
    @Binding var percentOfMachine: Bool

    private let cpuWidth: CGFloat = 60
    private let memWidth: CGFloat = 82

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sampler.processes) { row in
                        ProcessRowView(row: row,
                                       cpuText: cpuText(row.cpuPerCore),
                                       cpuColor: cpuColor(row.cpuPerCore),
                                       memText: memText(row.memBytes),
                                       cpuWidth: cpuWidth, memWidth: memWidth,
                                       onKill: { app.killProcessRow(row) })
                    }
                }
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: cpuWidth, alignment: .trailing)
            Text("Memory").frame(width: memWidth, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func cpuText(_ perCore: Double) -> String {
        if percentOfMachine {
            return String(format: "%.1f%%", perCore / Double(sampler.coreCount))
        }
        return String(format: "%.0f%%", perCore)
    }

    private func memText(_ bytes: Double) -> String {
        if percentOfMachine, sampler.totalMem > 0 {
            return String(format: "%.1f%%", bytes / sampler.totalMem * 100)
        }
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", bytes / 1_073_741_824)
        }
        return "\(Int(bytes / 1_048_576)) MB"
    }

    private func cpuColor(_ perCore: Double) -> Color {
        let normalized = perCore / Double(sampler.coreCount)
        if normalized > 50 || perCore > 90 { return .red }
        if normalized > 15 || perCore > 40 { return .orange }
        return .primary
    }
}

/// A single process row: icon + name on the left, CPU/Memory right-aligned. Supervised servers,
/// external dev servers and builds get a tinted background and a colored name so they stand out.
private struct ProcessRowView: View {
    let row: ProcessRow
    let cpuText: String
    let cpuColor: Color
    let memText: String
    let cpuWidth: CGFloat
    let memWidth: CGFloat
    let onKill: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                icon.frame(width: 15, alignment: .center)
                Text(row.name)
                    .fontWeight(emphasized ? .semibold : .regular)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if killable, hovering {
                    killButton   // appears right after the name on hover
                        .transition(.pop(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(cpuText).monospacedDigit().foregroundStyle(cpuColor)
                .frame(width: cpuWidth, alignment: .trailing)
            Text(memText).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: memWidth, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.feedback, value: hovering)
        .help(rowHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("CPU \(cpuText), memory \(memText)")
        .accessibilityActions {
            if killable { Button(killHelp, action: onKill) }
        }
    }

    /// Spoken row label: the process name plus its category (the hover help, first line).
    private var accessibilityLabel: String {
        if row.isPreview { return "\(row.name), supervised preview server" }
        if row.isDevServer { return "\(row.name), supervised dev server" }
        if row.isWorker { return "\(row.name), supervised worker" }
        if row.isExternalDev { return "\(row.name), external dev server" }
        if row.isExternalBuild { return "\(row.name), external build" }
        if row.isClaude { return "\(row.name), Claude Code shell" }
        if row.isBuild { return "\(row.name), build" }
        if row.isExtension { return "\(row.name), editor extension" }
        return row.name
    }

    /// A managed server / build is stopped through its supervisor; an external dev server or any
    /// other real process is killed by pid. Critical system processes and the editor (anything
    /// `ResourceAdvisor` protects) get no button, so a stray hover-click can't take down the session.
    private var killable: Bool {
        if row.isDevServer || row.isBuild || row.isWorker || row.isExternalDev || row.isExternalBuild || row.isClaude { return true }
        return row.id > 0 && !ResourceAdvisor.isProtected(row.name)
    }

    private var killButton: some View {
        Button(action: onKill) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help(killHelp)
    }

    private var killHelp: String {
        if row.isDevServer { return "Stop \(row.name)" }
        if row.isWorker { return "Stop \(row.name)" }
        if row.isBuild { return "Stop the build" }
        if row.isExternalBuild { return "Kill this unsupervised build (pid \(row.id))" }
        if row.isClaude { return "Stop this Claude shell (pid \(row.id))" }
        return "Kill \(row.name) (pid \(row.id))"
    }

    /// Full process name (it truncates in the middle) plus its category, shown on hover.
    private var rowHelp: String {
        let kind: String
        if row.isPreview { kind = " — supervised preview server" }
        else if row.isDevServer { kind = " — supervised dev server" }
        else if row.isWorker { kind = " — supervised worker" }
        else if row.isExternalDev { kind = " — external dev server (not supervised)" }
        else if row.isExternalBuild { kind = " — external build (not supervised)" }
        else if row.isClaude { kind = " — Claude Code shell (not supervised)" }
        else if row.isBuild { kind = " — build" }
        else if row.isExtension { kind = " — VS Code extension" }
        else { kind = "" }
        return "\(row.name)\(kind)\nCPU \(cpuText) · Memory \(memText)"
    }

    @ViewBuilder private var icon: some View {
        if row.isPreview {
            // Matches the Preview run-control's own icon (RunControl.swift) — an eye instead of the
            // server rack, so a preview row doesn't need " · preview" appended to its name to read
            // as one.
            Image(systemName: "eye.fill").foregroundStyle(.tint)
        } else if row.isDevServer {
            Image(systemName: "xserve").foregroundStyle(.tint)
        } else if row.isExternalDev {
            // Same glyph as a managed server, but purple = running outside the app.
            Image(systemName: "xserve").foregroundStyle(Color.indigo)
        } else if row.isExternalBuild {
            // The build's hammer, but indigo = running outside the app (like the external server tint).
            Image(systemName: "hammer.fill").foregroundStyle(Color.indigo)
        } else if row.isWorker {
            // A "gears" glyph marks a background worker — distinct from the server's rack and the
            // build's hammer.
            Image(systemName: "gearshape.2.fill").foregroundStyle(.teal)
        } else if row.isBuild {
            Image(systemName: "hammer.fill").foregroundStyle(.orange)
        } else if row.isExtension {
            // A generic "extension" glyph — marks the row as a VS Code/Cursor extension, not the
            // tech's own logo. Distinguishes it from a plain helper's gray dot.
            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
        } else if let logo = logoAsset {
            // Every app/brand logo — Claude shells/monitors and known GUI apps (Chrome, Notion,
            // Affinity, VS Code, Xcode, Safari, WhatsApp, Codex, Warp, Antigravity, the Claude desktop
            // app) — renders the SAME way: the monochrome asset in the theme's foreground colour, black
            // on light / white on dark, so it always contrasts.
            Image(logo).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 12, height: 12).foregroundStyle(.primary)
        } else if row.isSystem {
            // A macOS system / Apple background process — a gear so it reads distinctly from an
            // unrecognised user process (the plain dot below).
            Image(systemName: "gearshape.fill").font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
        }
    }

    /// The logo asset for a Claude shell/monitor or a known GUI app, matched on the process name — so
    /// every related process (main app, helpers, renderers, GPU) shares the icon, since helpers are
    /// named after their parent `.app` bundle. `nil` = no logo → a system glyph or the generic dot.
    private var logoAsset: String? {
        if row.isClaude { return "ClaudeLogo" }   // Claude Code's own shells/monitors
        let n = row.name.lowercased()
        if n.contains("owl monitor") || n.contains("owl-monitor") { return "OwlMonitorLogo" }  // us
        if n.contains("xcode") { return "XcodeLogo" }                          // before "code"
        if n.contains("chatgpt") { return "CodexLogo" }
        if n.contains("codex") { return "CodexLogo" }                          // before "code"
        if n.contains("visual studio code") || n == "code" { return "VSCodeLogo" }
        if n.contains("safari") { return "SafariLogo" }
        if n.contains("whatsapp") { return "WhatsAppLogo" }
        if n.contains("antigravity") { return "AntigravityLogo" }
        if n.contains("warp") { return "WarpLogo" }
        if n.contains("chrome") { return "ChromeLogo" }
        if n.contains("notion") { return "NotionLogo" }
        if n.contains("affinity") { return "AffinityLogo" }
        if n.contains("claude") { return "ClaudeLogo" }   // the Claude desktop app / CLI
        return nil
    }

    // Claude rows are deliberately NOT emphasized — red text but no tinted highlight (see nameColor).
    private var emphasized: Bool {
        row.isDevServer || row.isWorker || row.isExternalDev || row.isBuild
    }

    private var accent: Color {
        if row.isDevServer { return .accentColor }
        if row.isWorker { return .teal }
        if row.isExternalDev { return .indigo }
        if row.isBuild { return .orange }
        return .primary
    }

    // Claude shells/monitors: red name, but not "emphasized" so they get no background highlight.
    private var nameColor: Color {
        if row.isClaude { return .red }
        return emphasized ? accent : .primary
    }

    private var rowBackground: Color {
        if emphasized { return accent.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}
