import ChipCore
import Charts
import SwiftUI

// ------------------------------------------------------------------ fixed design canvas, scaled to fit
struct DesignCanvas<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / size.width, geo.size.height / size.height)
            content()
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

// ------------------------------------------------------------------ hover cards
extension View {
    /// Show a live hover card for this view. `make` is called on every redraw, so values stay current.
    func tip(_ id: String, _ make: @escaping () -> Tip?) -> some View {
        onHover { inside in
            let h = Hover.shared
            if inside { h.id = id; h.tip = make } else if h.id == id { h.id = nil; h.tip = nil }
        }
    }
}

struct TipOverlay: View {
    @Environment(UIState.self) private var ui
    @Environment(Hub.self) private var hub
    var body: some View {
        GeometryReader { geo in
            let h = Hover.shared
            if let make = h.tip, let t = (hub.latest != nil ? make() : nil) {
                let w: CGFloat = 300
                let x = h.location.x + 18 + w > geo.size.width ? h.location.x - w - 14 : h.location.x + 18
                TipCard(tip: t, explain: ui.explain)
                    .frame(width: w, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: x + w / 2, y: min(max(h.location.y + 90, 100), geo.size.height - 120))
                    .allowsHitTesting(false)
            }
        }
    }
}

struct TipCard: View {
    let tip: Tip
    let explain: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tip.value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text(tip.label).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            if !tip.rows.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(Array(tip.rows.enumerated()), id: \.offset) { _, r in
                    HStack { Text(r.0).foregroundStyle(Theme.ink2); Spacer(); Text(r.1).monospacedDigit() }.font(.system(size: 12))
                }
            }
            if explain, let e = tip.explain {
                Divider().padding(.vertical, 2)
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let s = tip.source { Text(s).font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 2) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x0B0B0B).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.axis))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

// ------------------------------------------------------------------ silicon block (a region of the die)
struct SiliconBlock: View {
    var rect: CGRect
    var title: String = ""
    var lines: [String] = []
    var heat: Double?                // nil = no load counter (stays plain silicon)
    var radius: CGFloat = 5
    var titleSize: CGFloat = 13
    var selected = false
    var body: some View {
        let h = heat ?? 0
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [Theme.siliconTop, Theme.siliconBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: radius).fill(heatColor(heat)).opacity(heat == nil ? 0 : 0.25 + 0.75 * min(1, h * 1.4))
            // hot blocks get a bright rim instead of a blurred shadow (shadows are expensive to composite)
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(selected ? Theme.ink : (h > 0.45 ? heatColor(min(1, h + 0.25)) : Color.white.opacity(0.12)), lineWidth: selected || h > 0.45 ? 2 : 1)
            if !title.isEmpty || !lines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !title.isEmpty { Text(title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(Theme.ink) }
                    ForEach(lines, id: \.self) { Text($0).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(h > 0.3 ? 0.95 : 0.75)) }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .lineLimit(1)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
    }
}

struct GhostBlock: View {
    var rect: CGRect
    var lines: [String]
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0x161615))
            Canvas { ctx, size in
                var x: CGFloat = -size.height
                while x < size.width {
                    var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(p, with: .color(Color(hex: 0x3A3935)), lineWidth: 2); x += 8
                }
            }.clipShape(RoundedRectangle(cornerRadius: 5))
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: 0x4A4944), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            VStack(spacing: 1) { ForEach(lines, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(Theme.muted) } }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

// ------------------------------------------------------------------ animated transport
struct Flow {
    var path: Path
    var rd: Double          // flows back toward the agent
    var wr: Double          // flows toward memory
    var peak: Double = 200e9
    var offset: CGSize = CGSize(width: 3, height: 0)
    var color: (Color, Color) = (Theme.read, Theme.write)
}

func line(_ a: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addLine(to: b); return p }

// ------------------------------------------------------------------ cards, stats, legends
struct Card<Content: View>: View {
    var title: String
    var note: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair))
    }
}

struct Stat: View {
    var value: String
    var label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

struct KV: View {
    var rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(Theme.ink2)
                    Text(r.1).monospacedDigit().fontWeight(.medium).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12))
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.muted).padding(.top, 14) }
}

struct LegendLine: View {
    var color: Color
    var label: String
    var body: some View { HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 16, height: 3); Text(label) }.font(.system(size: 11)).foregroundStyle(Theme.ink2) }
}

struct HeatLegend: View {
    var left = "idle", right = "max"
    var body: some View {
        HStack(spacing: 6) {
            Text(left)
            RoundedRectangle(cornerRadius: 3).fill(heatGradient).frame(width: 120, height: 9)
            Text(right)
        }
        .font(.system(size: 11)).foregroundStyle(Theme.ink2)
    }
}

// ------------------------------------------------------------------ history chart (one y-axis, hover readout)
struct Series: Identifiable { var id: String { name }; var name: String; var color: Color; var values: [Double?] }

struct HistoryChart: View {
    var series: [Series]
    var yMax: Double? = nil
    var format: (Double) -> String
    var height: CGFloat = 120
    var body: some View {
        let n = series.map(\.values.count).max() ?? 0
        Chart {
            ForEach(series) { s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { i, v in
                    if let v {
                        LineMark(x: .value("t", Double(i - n + 1) / 4), y: .value(s.name, v), series: .value("s", s.name))
                            .foregroundStyle(s.color).lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }
        }
        .chartXScale(domain: -60...0)
        .chartYScale(domain: 0...(yMax ?? max(1e-9, series.flatMap { $0.values.compactMap { $0 } }.max() ?? 1) * 1.1))
        .chartXAxis { AxisMarks(values: [-60, -30, 0]) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "now" : "\(Int(d)) s") } } } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
            AxisGridLine().foregroundStyle(Theme.grid)
            AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(.system(size: 10)) } }
        } }
        .chartLegend(.hidden)
        .frame(height: height)
    }
}
