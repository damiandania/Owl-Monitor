import SwiftUI
import AppKit

extension View {
    /// Inset rounded "card" surface used across the detail pane — the modal/System-Settings look
    /// (control-tinted fill on the window-tinted base, soft shadow).
    ///
    /// The shadow belongs to the BACKGROUND SHAPE, not the card. Applied to the whole card (as it
    /// used to be), SwiftUI derives it from the alpha of everything inside — every glyph and icon —
    /// so any change to the content re-rasterized the card on the CPU and re-ran a Gaussian blur over
    /// it. These cards hold a once-a-second "Running for" timer, meters resampled every 2 s and a
    /// streaming log, which kept the app near 18 % CPU while idle. Cast by the static shape, the
    /// shadow is computed once and content updates never touch it; visually it's the same.
    func dmCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
            }
    }
}
