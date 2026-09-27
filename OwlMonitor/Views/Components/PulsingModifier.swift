import SwiftUI

/// Fades a view in and out while `active` — the shared "in progress" signal (e.g. a run-control's
/// text blinks while launching/building). When `active` is false it sits at full opacity.
///
/// Honors Reduce Motion: an endless blink is exactly what that setting asks apps to stop, so with it
/// on the view holds steady at full opacity. "In progress" still reads — the pill is orange and its
/// label says "Launching…"/"Building…" — just without anything flashing.
private struct PulsingModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            // Gated on reduceMotion here, not only in startPulsing, so flipping the setting on
            // mid-pulse stops the flashing at once instead of waiting for the next state change.
            .opacity(active && dim && !reduceMotion ? 0.4 : 1)
            .onAppear { if active { startPulsing() } }
            .onChange(of: active) { _, now in
                if now { startPulsing() } else { withAnimation(Motion.feedback) { dim = false } }
            }
            .onChange(of: reduceMotion) { _, _ in if active { startPulsing() } }
    }

    private func startPulsing() {
        dim = false
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
    }
}

extension View {
    /// Blink (fade) this view while `active`. Default `true` pulses forever, like an in-progress mark.
    func pulsing(active: Bool = true) -> some View { modifier(PulsingModifier(active: active)) }
}
