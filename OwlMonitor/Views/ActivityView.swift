import SwiftUI

/// Global activity card: system CPU / Memory / Swap meters + the process table (all processes;
/// each supervised server its own row, external dev servers identified). Not tied to a project.
struct ActivityView: View {
    @Environment(AppState.self) private var app
    @State private var percentOfMachine = false
    /// Collapsed by default: the card shows just the meters until the user expands the process list.
    @State private var expanded = false
    /// The timeline-charts accordion, sibling to the process list. Ephemeral like `expanded`.
    @State private var chartsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            meterRow
            // Timeline-charts accordion (only when the setting is on) — same collapse pattern as the
            // process list below: always in the hierarchy, height/opacity/clip animated by the card
            // spring. Its 2 Hz churn is isolated inside ActivityTimelineView.
            if app.settings.showCharts {
                VStack(spacing: 0) {
                    disclosure(title: chartsExpanded ? "Hide charts" : "Show charts",
                               isOpen: chartsExpanded) { chartsExpanded.toggle() }
                    // Collapsed content is UNMOUNTED (`if`), not merely zero-height: a hidden view's
                    // body still re-evaluates on every observed tick, so a "collapsed" timeline kept
                    // re-rendering 3×300 chart points at 2 Hz invisibly. The container still animates
                    // the height (the accordion), and the child fades via its transition.
                    Group {
                        if chartsExpanded {
                            ActivityTimelineView(sampler: app.systemSampler).transition(.opacity)
                        }
                    }
                    .frame(height: chartsExpanded ? 172 : 0)
                    .padding(.top, chartsExpanded ? 8 : 0)
                    .clipped()
                    .accessibilityHidden(!chartsExpanded)
                }
            }
            // Disclosure region: the container collapses to zero height and is clipped, so
            // expand/collapse is a smooth accordion driven by a single spring on the card. The table
            // itself is unmounted while collapsed — same reasoning as the charts above.
            VStack(spacing: 0) {
                disclosure(title: expanded ? "Hide processes" : "Show processes",
                           isOpen: expanded) { expanded.toggle() }
                Group {
                    if expanded {
                        ProcessTableView(sampler: app.systemSampler, percentOfMachine: $percentOfMachine)
                            .transition(.opacity)
                    }
                }
                .frame(height: expanded ? 240 : 0)
                .padding(.top, expanded ? 10 : 0)
                .clipped()
                .accessibilityHidden(!expanded)
            }
        }
        .dmCard()
        .animation(Motion.region(reduceMotion), value: expanded)
        .animation(Motion.region(reduceMotion), value: chartsExpanded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Activity", systemImage: "cpu.fill").font(.headline)
            Spacer()
            if expanded {
                Toggle(isOn: $percentOfMachine) {
                    Text("% of machine").font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .help("Show each process's CPU as a share of the whole machine instead of per-core")
                // Only meaningful with the process list open — so it arrives and leaves with it.
                .transition(.pop(reduceMotion: reduceMotion))
            }
        }
    }

    /// Shared disclosure control (chevron rotates when open) — drives both the charts and the
    /// process-list accordions so they look and behave identically.
    private func disclosure(title: LocalizedStringKey, isOpen: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Meters

    private struct Meter: Identifiable {
        let id: String
        let title: String
        let percent: Double      // 0…100
        let detail: String
        let color: Color
        let icon: String
    }

    /// The meters to render, in the order the user configured in settings.
    private var meters: [Meter] {
        let s = app.systemSampler
        let gb = 1_073_741_824.0
        func ratio(_ used: Double, _ total: Double) -> String {
            String(format: "%.1f / %.0f GB", used / gb, total / gb)
        }
        return app.settings.bars.compactMap { id in
            switch id {
            case "cpu":
                return Meter(id: id, title: "CPU", percent: s.systemCPU,
                             detail: "\(Int(s.systemCPU))%", color: .blue, icon: "cpu.fill")
            case "memory":
                return Meter(id: id, title: "Memory", percent: s.systemMemPercent,
                             detail: ratio(s.systemMemUsed, s.totalMem), color: .indigo, icon: "memorychip.fill")
            case "swap":
                return Meter(id: id, title: "Swap", percent: s.systemSwapPercent,
                             detail: s.systemSwapTotal > 0 ? ratio(s.systemSwapUsed, s.systemSwapTotal) : "off",
                             color: .orange, icon: "arrow.left.arrow.right")
            case "load":
                return Meter(id: id, title: "Load", percent: min(100, s.loadAverage / Double(s.coreCount) * 100),
                             detail: String(format: "%.2f", s.loadAverage), color: .teal, icon: "speedometer")
            case "devcpu":
                return Meter(id: id, title: "Dev CPU", percent: min(100, s.devTreeCPU / Double(s.coreCount)),
                             detail: "\(Int(s.devTreeCPU))%", color: .green, icon: "xserve")
            case "devmem":
                return Meter(id: id, title: "Dev RAM", percent: s.totalMem > 0 ? s.devTreeMem / s.totalMem * 100 : 0,
                             detail: String(format: "%.0f MB", s.devTreeMem / 1_048_576), color: .green, icon: "xserve")
            case "temp":
                let t = s.cpuTemperature
                // Map °C onto the 0–100 bar with 90 °C = full, so 45 °C reads as exactly half.
                return Meter(id: id, title: "Temp", percent: t > 0 ? min(100, t / 90 * 100) : 0,
                             detail: t > 0 ? "\(Int(t.rounded()))°C" : "—",
                             color: Self.tempColor(t), icon: "thermometer")
            default:
                return nil
            }
        }
    }

    /// Adaptive grid: tiles keep a comfortable min width and wrap to more rows as the bar count
    /// grows / the window narrows — instead of cramming everything onto one row and wrapping text.
    private var meterRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(meters) { m in
                MeterTile(title: m.title, detail: m.detail,
                          fraction: min(max(m.percent / 100, 0), 1),
                          color: m.color, icon: m.icon, help: meterHelp(m))
            }
        }
    }

    /// Human description + live value for a meter tile, shown on hover.
    private func meterHelp(_ m: Meter) -> String {
        let desc: String
        switch m.id {
        case "cpu":    desc = "System CPU usage across all cores"
        case "memory": desc = "System memory in use / total"
        case "swap":   desc = "Swap space in use / total"
        case "load":   desc = "1-minute load average"
        case "devcpu": desc = "CPU used by the dev-server process tree"
        case "devmem": desc = "Memory used by the dev-server process tree"
        case "temp":   desc = "Average CPU / SoC temperature"
        default:       desc = m.title
        }
        return "\(desc) — \(m.detail)"
    }

    /// Temperature tile colour: green cool → red hot; gray when no sensor is readable (t < 0).
    private static func tempColor(_ t: Double) -> Color {
        switch t {
        case ..<0:  return .gray
        case ..<60: return .green
        case ..<80: return .yellow
        case ..<90: return .orange
        default:    return .red
        }
    }
}

/// One activity meter rendered as a tile (icon + title, the value, a capsule bar). Shared by EVERY
/// meter so they all look identical — fixed type sizes, so a longer value like "12.4 / 14 GB" never
/// renders at a different scale than a shorter one like "5.8 / 8 GB". The adaptive grid keeps each
/// tile wide enough for the longest value, so `lineLimit(1)` alone prevents wrapping (no shrinking).
private struct MeterTile: View {
    let title: String
    let detail: String
    let fraction: Double   // 0…1
    let color: Color
    let icon: String
    let help: String

    // Deliberately NOT animated — neither the digits nor the bar (see MeterBar).

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(detail).font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color).lineLimit(1)
            }
            MeterBar(value: fraction, color: color)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

/// A rounded capsule meter with a neutral track — replaces the thin gray `ProgressView`.
///
/// Deliberately NOT animated. The meters resample every ~2 s, so gliding the bars (and rolling the
/// digits) meant the Activity card re-laid-out and re-rendered on the CPU, frame by frame, for a
/// third of all wall time — measured at ~17 % of a core with no servers running, against 0.9 %
/// without it. A monitor for RAM-constrained Macs must not itself be the load it's watching; a value
/// that simply updates in place is the right trade for an always-on instrument.
private struct MeterBar: View {
    let value: Double      // 0…1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: value > 0 ? max(5, geo.size.width * value) : 0)
            }
        }
        .frame(height: 6)
    }
}
