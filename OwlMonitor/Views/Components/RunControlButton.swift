import SwiftUI

extension Color {
    /// The preview pill / tab / menu-bar dot: a production BUILD being served, not dev sources — a
    /// distinct colour so it's never mistaken for the green dev server at a glance. Deep enough to
    /// keep the pill's white label readable (~5:1 contrast).
    static let previewMagenta = Color(red: 0.80, green: 0.10, blue: 0.55)
}

/// The unified status of a run-control, so all four pills (dev / worker / build / preview) derive
/// their colour, label, icon and in-progress animation from ONE place and stay perfectly consistent
/// (e.g. "Stopped" is red everywhere, "Building…"/"Launching…" pulse everywhere). Equatable so a
/// view can animate on ANY transition (colour, label, icon) with a single `.animation(value:)`.
enum RunStatus: Equatable {
    case idle               // not started — gray, no label, ▶
    case starting(String)   // launching / building — orange, pulsing, ■
    case running(String)    // up — green, ■
    case serving(String)    // preview serving the production build — magenta, ■
    case done(String)       // finished OK (a build) — green, ▶
    case stopped            // cleanly stopped — red, ▶
    case failed(String)     // crashed / errored — red, ▶; the String is the terminal error

    var label: String {
        switch self {
        case .idle: return ""
        case .starting(let l), .running(let l), .serving(let l), .done(let l): return l
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .starting: return .orange
        case .running, .done: return .green
        case .serving: return .previewMagenta
        case .stopped, .failed: return .red
        }
    }

    /// Stop icon while in progress / up; play icon otherwise.
    var showsStop: Bool {
        switch self { case .starting, .running, .serving: return true; default: return false }
    }

    /// Blink the pill while launching / building to signal work in progress.
    var isInProgress: Bool { if case .starting = self { return true }; return false }

    /// Came up or finished OK — the moment the pill pops once to confirm it (see `View.pop`).
    var isSuccess: Bool {
        switch self { case .running, .serving, .done: return true; default: return false }
    }

    /// Terminal error to show in the popover (when set, the state word is an underlined link).
    var error: String? { if case .failed(let e) = self { return e }; return nil }
}

/// One project run-control — dev server, worker, or build — as a single tinted pill: the play/stop
/// icon plus the action name (bold) and a short status live inside, and tapping the pill toggles it.
/// When failed, the status word is underlined and opens a popover with the terminal error. While
/// launching/building the pill pulses. All three dashboard controls share this and one `RunStatus`.
struct RunControlButton: View {
    let title: String
    let status: RunStatus
    let onToggle: () -> Void

    @State private var showError = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.showsStop ? "stop.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                // Morph ▶ ↔ ■ instead of swapping glyphs abruptly.
                .contentTransition(.symbolEffect(.replace))
            HStack(spacing: 5) {
                Text(title).fontWeight(.bold)
                stateLabel
            }
            .font(.callout)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)   // never wrap "Preview" → "Pre-view"
            // Blink just the text (not the whole pill) while launching/building.
            .pulsing(active: status.isInProgress)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(status.color, in: Capsule())
        // A custom tap target has no native button chrome, so hover is the only cue it's clickable.
        .brightness(hovering ? 0.07 : 0)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        // The pill (everything except the underlined error word) toggles play/stop.
        .onTapGesture(perform: onToggle)
        .help(status.showsStop ? "Stop \(title.lowercased())" : "Start \(title.lowercased())")
        // One animation for every state change — the colour cross-fades (gray → orange → green /
        // magenta → red) and the pill eases to its new label's width, instead of jumping. Under
        // Reduce Motion it's a short fade: a colour change isn't motion, so it still reads.
        .animation(Motion.state(reduceMotion), value: status)
        .animation(Motion.feedback, value: hovering)
        // One-shot punctuation for the two moments that matter: a crash shakes the pill once, and
        // coming up / finishing OK pops it once. Neither plays on appearance, only on the change.
        .shake(when: status.error != nil)
        .pop(when: status.isSuccess)
        // VoiceOver: the pill is a custom tap target, so expose it as a button with the action name
        // and current state, and route the tap through an accessibility action.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(status.showsStop ? "Stop" : "Start") \(title)")
        .accessibilityValue(status.label)
        .accessibilityAction(.default, onToggle)
    }

    @ViewBuilder private var stateLabel: some View {
        let label = status.label
        if label.isEmpty {
            EmptyView()   // idle → show just the name
        } else if let error = status.error {
            // Underlined + clickable → opens the error popover. Being a Button, it consumes the tap
            // so the pill's play/stop gesture doesn't also fire.
            Button { showError = true } label: {
                Text(LocalizedStringKey(label)).underline()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showError, arrowEdge: .bottom) {
                ErrorPopover(title: title, detail: error)
            }
        } else {
            Text(LocalizedStringKey(label))
                .contentTransition(.opacity)   // "Launching…" → "Running" cross-fades, not swaps
        }
    }
}

/// The failure dialog opened from a run-control's underlined state: the terminal error, selectable
/// and copyable.
private struct ErrorPopover: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(title) error", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red)
                Spacer(minLength: 16)
                CopyButton(text: detail, help: "Copy the \(title.lowercased()) error")
            }
            ScrollView {
                Text(detail.isEmpty ? "No output." : detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)   // override the white inherited from the pill
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 440, height: 260)
        }
        .padding(14)
    }
}
