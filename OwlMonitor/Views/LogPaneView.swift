import SwiftUI
import AppKit

/// Live, auto-scrolling terminal log. With `onSubmit` set it also shows an input field (used for
/// the dev server's stdin); without it, it's a read-only viewer (used for the build log).
struct LogPaneView: View {
    let lines: [String]
    var inputPlaceholder: String? = nil
    var onSubmit: ((String) -> Void)? = nil
    /// A status strip (e.g. a run timer) pinned at the bottom in place of the stdin input.
    var footer: AnyView? = nil
    /// Terminal appearance: "app" (follow the app theme), "dark", or "light".
    var terminalTheme: String = "dark"
    @State private var input = ""
    @State private var search = ""
    @State private var copied = false
    /// Cancels a pending "revert the copied checkmark" so rapid re-copies don't flicker back early.
    @State private var resetCopied: Task<Void, Never>? = nil
    @Environment(\.colorScheme) private var appScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Lines actually shown: filtered by the search query (matched against ANSI-stripped text).
    private var visibleLines: [String] { LogFilter.filter(lines, query: search) }

    /// Resolve the effective terminal scheme — "app" follows the app's appearance.
    private var dark: Bool {
        switch terminalTheme {
        case "light": return false
        case "dark": return true
        default: return appScheme == .dark
        }
    }

    var body: some View {
        let textColor = dark ? Color(white: 0.85) : Color(white: 0.18)
        let bgColor = dark ? Color(white: 0.08) : Color(white: 0.98)
        let inputText = dark ? Color.white : Color.black
        let inputBg = dark ? Color(white: 0.12) : Color(white: 0.94)
        let border = (dark ? Color.white : Color.black).opacity(0.08)

        let shown = visibleLines

        VStack(spacing: 0) {
            // Search + copy strip. Filtering matches the ANSI-stripped text; the copy button puts the
            // currently shown lines (so a filtered view copies just the matches) on the clipboard.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Filter log", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(inputText)
                if !search.isEmpty {
                    // No rolling digits here on purpose: the counter tracks a live log that can emit
                    // hundreds of lines a second, so it would never stop moving.
                    Text("\(shown.count)/\(lines.count)").font(.caption2).foregroundStyle(.secondary)
                        .transition(.pop(reduceMotion: reduceMotion))
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .transition(.pop(reduceMotion: reduceMotion))
                }
                copyButton(shown)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(inputBg)
            .animation(Motion.state(reduceMotion), value: search.isEmpty)
            Divider()

            // AppKit-backed so a click-drag can select across MANY lines (a stack of SwiftUI `Text`s
            // can only select within one row) and so chatty output stays smooth on large logs.
            TerminalTextView(lines: shown, textColor: textColor, background: bgColor)

            if let footer {
                Divider()
                footer
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(inputBg)
            } else if let placeholder = inputPlaceholder, let onSubmit {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                    TextField(placeholder, text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(inputText)
                        .onSubmit {
                            guard !input.isEmpty else { return }
                            onSubmit(input)
                            input = ""
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(inputBg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Copy-all button: turns into a green checkmark + "Copied" for a beat, popping once as it does,
    /// so the click registers. (It used to stay blown up to 115 % the whole time — a success is
    /// confirmed by a brief pop that settles, not by a held enlargement.)
    @ViewBuilder private func copyButton(_ shown: [String]) -> some View {
        Button { copyAll(shown) } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                if copied {
                    Text("Copied").font(.caption2.weight(.medium))
                        .transition(.rise(reduceMotion: reduceMotion))
                }
            }
            .font(.caption)
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .pop(when: copied)
        }
        .buttonStyle(.plain)
        .help(search.isEmpty ? "Copy the whole log to the clipboard"
                             : "Copy the filtered log to the clipboard")
        .disabled(shown.isEmpty)
        .animation(Motion.state(reduceMotion), value: copied)
    }

    /// Put the shown lines (ANSI-stripped, so it pastes as plain text) on the clipboard and flash the
    /// checkmark for ~1.3s.
    private func copyAll(_ shown: [String]) {
        let text = shown.map(\.strippedANSI).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        copied = true
        resetCopied?.cancel()
        resetCopied = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            copied = false   // animated by the button's own `.animation(value: copied)`
        }
    }
}

/// AppKit terminal text: an `NSTextView` gives native multi-line click-drag selection and `⌘C`, plus
/// TextKit's lazy layout (only visible glyphs) so a 2000-line log doesn't re-lay-out wholesale on
/// every chatty burst the way one giant SwiftUI `Text` would. Read-only; follows the tail unless the
/// user has scrolled up or is mid-selection.
private struct TerminalTextView: NSViewRepresentable {
    let lines: [String]
    let textColor: Color
    let background: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true

        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true   // wrap to width, no horizontal scroll

        context.coordinator.scroll = scroll
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(lines: lines, textColor: NSColor(textColor), background: NSColor(background))
    }

    final class Coordinator {
        weak var scroll: NSScrollView?
        weak var textView: NSTextView?

        /// What the document currently shows, so a live burst appends ONLY the new tail instead of
        /// re-attributing and re-laying-out all ~2000 lines on every chunk (the strings share storage
        /// with the source array, so the prefix comparison is pointer-fast).
        private var rendered: [String] = []
        private var renderedColor: NSColor?

        private let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        private let boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)

        func apply(lines: [String], textColor: NSColor, background: NSColor) {
            guard let tv = textView, let scroll = scroll else { return }
            tv.backgroundColor = background
            scroll.backgroundColor = background

            // Leave the text (and thus the selection) untouched while the user is selecting — a live
            // burst mustn't yank the highlight out from under a drag. It catches up on the next update.
            guard tv.selectedRange().length == 0 else { return }

            let sameTheme = renderedColor == textColor
            // Unrelated SwiftUI update (hover, timer, …) — the log itself didn't change.
            if sameTheme, lines.count == rendered.count, lines.elementsEqual(rendered) { return }

            let atBottom = isScrolledToBottom(scroll)

            if sameTheme, lines.count > rendered.count, lines.prefix(rendered.count).elementsEqual(rendered) {
                // Pure append — the common case for live output.
                let tail = NSMutableAttributedString()
                var needsNewline = !rendered.isEmpty
                for line in lines[rendered.count...] {
                    if needsNewline { tail.append(NSAttributedString(string: "\n")) }
                    needsNewline = true
                    tail.append(attributed(line.isEmpty ? " " : line, textColor: textColor))
                }
                tv.textStorage?.append(tail)
            } else {
                // Front-trim, filter or theme change — rebuild wholesale (rare: at most once per
                // trim batch, or on a user action).
                let full = NSMutableAttributedString()
                for (i, line) in lines.enumerated() {
                    if i > 0 { full.append(NSAttributedString(string: "\n")) }
                    full.append(attributed(line.isEmpty ? " " : line, textColor: textColor))
                }
                tv.textStorage?.setAttributedString(full)
            }
            rendered = lines
            renderedColor = textColor

            // Only follow the tail if the user was already parked there — don't fight a scroll-up.
            if atBottom { tv.scrollToEndOfDocument(nil) }
        }

        private func isScrolledToBottom(_ scroll: NSScrollView) -> Bool {
            guard let doc = scroll.documentView else { return true }
            // Within ~one line of the bottom counts as "following the tail".
            return scroll.contentView.bounds.maxY >= doc.bounds.height - 20
        }

        /// Reuse the cached SwiftUI ANSI parse, re-emitting each run as AppKit attributes (SwiftUI
        /// `Color` → `NSColor`, strong emphasis → bold monospaced), defaulting to the theme text colour.
        private func attributed(_ line: String, textColor: NSColor) -> NSAttributedString {
            let parsed = ANSI.attributed(line)
            let out = NSMutableAttributedString()
            for run in parsed.runs {
                let text = String(parsed[run.range].characters)
                let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                var attrs: [NSAttributedString.Key: Any] = [.font: bold ? boldFont : font]
                attrs[.foregroundColor] = run.foregroundColor.map(NSColor.init) ?? textColor
                out.append(NSAttributedString(string: text, attributes: attrs))
            }
            return out
        }
    }
}
