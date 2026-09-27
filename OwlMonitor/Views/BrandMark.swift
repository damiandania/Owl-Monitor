import SwiftUI

/// The owl + wordmark lockup — the app's brand, shown at the top of the sidebar and of Settings.
///
/// The owl is a two-tone asset with a dark-appearance variant (`OwlLogo.imageset`): the head and the
/// facial disc are opposite colours, and the catalog swaps the whole pair per appearance. So unlike the
/// glyphs around it it must NOT get `.renderingMode(.template)` — that would flatten head and face into
/// a single tint and the owl would lose its eyes.
struct BrandMark: View {
    /// Height of the owl; its width follows the artwork's aspect ratio, and the wordmark is sized off
    /// this so the lockup scales as one unit.
    var size: CGFloat = 22
    /// Show the running version under the name (Settings does, the sidebar doesn't).
    var showsVersion = false
    /// Drop the wordmark and show the owl alone. The sidebar toolbar needs this: the full lockup is wide
    /// enough to push the "add project" button out of the toolbar entirely, and the window title a few
    /// points away already reads "Owl Monitor".
    var showsWordmark = true

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        HStack(spacing: size * 0.36) {
            Image("OwlLogo")
                .resizable()
                .scaledToFit()
                // Height only: the mark is wider than it is tall, so pinning it into a square frame
                // would letterbox it and render the owl smaller than `size` claims.
                .frame(height: size)
                // With the wordmark present it would say the name twice; alone, the owl has to carry it.
                .accessibilityHidden(showsWordmark)
                .accessibilityLabel(showsWordmark ? "" : "Owl Monitor")
            if showsWordmark {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Owl Monitor")
                        .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                    if showsVersion {
                        Text("Version \(version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
