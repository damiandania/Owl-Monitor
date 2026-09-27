import SwiftUI
import AppKit

/// A small icon button that copies `text` to the clipboard and briefly flips to a green checkmark,
/// popping once as it does, so the user gets clear feedback that it worked.
struct CopyButton: View {
    let text: String
    var help: String = "Copy"
    @State private var copied = false
    /// Cancels a pending revert, so a quick second copy isn't undone early by the first one's timer.
    @State private var resetCopied: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            resetCopied?.cancel()
            resetCopied = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Color.green : .secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
                .pop(when: copied)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : help)
        .animation(Motion.state(reduceMotion), value: copied)
    }
}
