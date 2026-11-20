import ChipCore
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum Theme {
    static let page = Color(hex: 0x0D0D0D), surface = Color(hex: 0x1A1A19), surface2 = Color(hex: 0x222220)
    static let ink = Color(hex: 0xF0EFEC), ink2 = Color(hex: 0xC3C2B7), muted = Color(hex: 0x898781)
    static let grid = Color(hex: 0x2C2C2A), axis = Color(hex: 0x383835), hair = Color.white.opacity(0.10)
    static let read = Color(hex: 0x3987E5), write = Color(hex: 0x199E70), power = Color(hex: 0xC98500)
    static let good = Color(hex: 0x0CA30C), warning = Color(hex: 0xFAB219), critical = Color(hex: 0xD03B3B)
    static let series = [Color(hex: 0x3987E5), Color(hex: 0xD95926), Color(hex: 0x199E70), Color(hex: 0xC98500), Color(hex: 0xD55181),
                         Color(hex: 0x0CA30C), Color(hex: 0x9085E9), Color(hex: 0xE66767)]
    // physical materials
    static let siliconTop = Color(hex: 0x34343F), siliconBottom = Color(hex: 0x24242C)
    static let substrate = Color(hex: 0x15171A), pcb = Color(hex: 0x0E3A2B), pcbTrace = Color(hex: 0x1C5A42)
    static let copper = Color(hex: 0xB87333), epoxy = Color(hex: 0x111113), aluminium = Color(hex: 0x2A2B2E)
    static let mono = Font.system(size: 11, design: .monospaced)
}

/// Semantic heat ramp: idle slate -> deep red -> red -> hot orange. Always shown with its legend.
private let HEAT: [(Double, (Double, Double, Double))] = [(0, (42, 44, 48)), (0.15, (74, 38, 48)), (0.35, (138, 31, 44)),
                                                          (0.6, (201, 38, 43)), (0.85, (240, 65, 43)), (1, (255, 106, 61))]
func heatRGB(_ x: Double) -> (Double, Double, Double) {
    let x = max(0, min(1, x.isFinite ? x : 0))
    for i in 1..<HEAT.count where x <= HEAT[i].0 {
        let (t0, c0) = HEAT[i - 1], (t1, c1) = HEAT[i]
        let f = (x - t0) / (t1 - t0)
        return (c0.0 + (c1.0 - c0.0) * f, c0.1 + (c1.1 - c0.1) * f, c0.2 + (c1.2 - c0.2) * f)
    }
    return HEAT.last!.1
}
func heatColor(_ x: Double?) -> Color {
    guard let x else { return Color(hex: 0x202124) }
    let c = heatRGB(x)
    return Color(.sRGB, red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
}
var heatGradient: LinearGradient {
    LinearGradient(stops: HEAT.map { .init(color: heatColor($0.0), location: $0.0) }, startPoint: .leading, endPoint: .trailing)
}
/// Temperature -> heat ramp (35 °C idle .. 100 °C max).
func tempColor(_ c: Double?) -> Color { heatColor(c.map { ($0 - 35) / 65 }) }

enum Fmt {
    static func bps(_ b: Double?) -> String {
        guard let b else { return "—" }
        if b >= 1e9 { return String(format: b >= 1e10 ? "%.0f GB/s" : "%.1f GB/s", b / 1e9) }
        if b >= 1e6 { return String(format: b >= 1e8 ? "%.0f MB/s" : "%.1f MB/s", b / 1e6) }
        if b >= 1e3 { return String(format: "%.0f kB/s", b / 1e3) }
        return String(format: "%.0f B/s", b)
    }
    static func bytes(_ b: Int?) -> String {
        guard let b else { return "—" }
        let d = Double(b)
        if d >= 1073741824 { return String(format: d >= 10737418240 ? "%.1f GB" : "%.2f GB", d / 1073741824) }
        if d >= 1048576 { return String(format: "%.0f MB", d / 1048576) }
        return String(format: "%.0f KB", d / 1024)
    }
    static func w(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 0.1 ? String(format: "%.0f mW", v * 1000) : String(format: v < 10 ? "%.2f W" : "%.1f W", v)
    }
    static func pct(_ x: Double?) -> String { x.map { String(format: $0 < 0.1 ? "%.1f%%" : "%.0f%%", $0 * 100) } ?? "—" }
    static func mhz(_ m: Double?) -> String {
        guard let m, m > 0 else { return "—" }
        return m >= 1000 ? String(format: "%.2f GHz", m / 1000) : String(format: "%.0f MHz", m)
    }
    static func ns(_ n: Double?) -> String {
        guard let n else { return "—" }
        switch n {
        case ..<10: return String(format: "%.2f ns", n)
        case ..<1000: return String(format: "%.0f ns", n)
        case ..<1e6: return String(format: n < 1e4 ? "%.2f µs" : "%.0f µs", n / 1e3)
        case ..<1e9: return String(format: n < 1e7 ? "%.2f ms" : "%.0f ms", n / 1e6)
        default: return String(format: "%.2f s", n / 1e9)
        }
    }
    static func temp(_ c: Double?) -> String { c.map { String(format: "%.1f °C", $0) } ?? "—" }
}

/// Block colour = linear share of a block's capacity (so red really means busy).
func lin(_ v: Double, _ peak: Double) -> Double { v > 0 ? min(1, v / peak) : 0 }
/// Flow width/speed: log scale from 1 MB/s to `peak`, so small streams stay visible.
func logBW(_ v: Double, _ peak: Double = 200e9) -> Double {
    v <= 0 ? 0 : max(0, min(1, log10(1 + v / 1e6) / log10(1 + peak / 1e6)))
}

extension UIState {
    func coreHeat(_ c: CoreSample?, type: String, freqs: [Int]) -> Double? {
        guard let c else { return nil }
        switch heatBy {
        case .busy: return c.busy
        case .work: return c.busy * (c.mhz ?? 0) / Double(freqs.max() ?? 1)
        case .power: return c.w / (type == "P" ? 5 : 0.6)
        }
    }
    func gpuHeat(_ g: GPUSample, freqs: [Int]) -> Double {
        let u = g.util ?? g.busy
        switch heatBy {
        case .busy: return u
        case .work: return u * (g.mhz ?? 0) / Double(freqs.max() ?? 1)
        case .power: return g.w / 20
        }
    }
}
