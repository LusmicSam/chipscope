import ChipCore
import SwiftUI

/// Top-down inside view of the MacBook Pro, drawn as hardware and coloured by live load.
struct MacView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui

    var body: some View {
        DesignCanvas(size: CGSize(width: 1180, height: 820)) {
            if let f = hub.current(ui) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    MacBody(f: f, topo: hub.topo, temps: nil)
                    FlowLayer(flows: flows(f))
                    interactive(f)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder private func interactive(_ f: Frame) -> some View {
        let t = hub.topo, b = f.board
        // the chip: click to go deeper
        SiliconBlock(rect: CGRect(x: 505, y: 222, width: 190, height: 160), title: t.chip, lines: ["\(Fmt.w(f.chip.socW)) CPU+GPU+ANE", "CPU \(Fmt.pct(avgBusy(f))) · GPU \(Fmt.pct(f.chip.gpu.util ?? f.chip.gpu.busy))", b.socMax.map { "die sensors \(Fmt.temp($0))" } ?? ""],
                     heat: lin(f.chip.socW, 40), radius: 4)
            .onTapGesture { ui.go(.soc) }
            .tip("mac.soc") { Tip(value: Fmt.w(f.chip.socW), label: "\(t.chip) · click to open the chip",
                                  rows: [("CPU", Fmt.w(f.chip.cpuW)), ("GPU", Fmt.w(f.chip.gpu.w)), ("Neural Engine", Fmt.w(f.chip.aneW)), ("Die sensors (max)", Fmt.temp(b.socMax))],
                                  source: "IOReport Energy Model · HID PMU sensors") }
        ForEach(0..<2, id: \.self) { i in
            MemoryPackage(rect: CGRect(x: 705, y: 222 + CGFloat(i) * 82, width: 92, height: 76), heat: lin(f.chip.mem.dram, t.spec.memPeakBW), lines: [Fmt.bps(f.chip.mem.dram / 2)])
                .onTapGesture { ui.go(.memory) }
                .tip("mac.dram") { Tip(value: Fmt.bps(f.chip.mem.dram), label: "Unified memory (\(Fmt.bytes(t.memoryBytes)))", rows: [("DRAM power", Fmt.w(f.chip.mem.dramW))]) }
        }
        ForEach(0..<2, id: \.self) { i in
            Chip(rect: CGRect(x: 360, y: 214 + CGFloat(i) * 90, width: 110, height: 76), label: "NAND", sub: i == 0 ? "R \(Fmt.bps(b.disk.rdBps))" : "W \(Fmt.bps(b.disk.wrBps))",
                 heat: lin(b.disk.rdBps + b.disk.wrBps, 7e9))
                .tip("mac.nand") { Tip(value: Fmt.bps(b.disk.rdBps + b.disk.wrBps), label: "SSD · \(t.ssdModel)",
                                       rows: [("Read", Fmt.bps(b.disk.rdBps)), ("Write", Fmt.bps(b.disk.wrBps)), ("Read latency (driver)", b.disk.rdLatUs.map { String(format: "%.0f µs", $0) } ?? "—"),
                                              ("NAND temperature", Fmt.temp(b.ssdTemp))],
                                       explain: "NAND flash chips. The controller that runs them (ANS) is inside the SoC.", source: "IOBlockStorageDriver Statistics · HID NAND sensor") }
        }
        Chip(rect: CGRect(x: 820, y: 214, width: 92, height: 80), label: "Wi-Fi/BT", sub: "↓ \(Fmt.bps(b.wifi.rx))", heat: lin(b.wifi.rx + b.wifi.tx, 150e6))
            .tip("mac.wifi") { Tip(value: Fmt.bps(b.wifi.rx + b.wifi.tx), label: "Wi-Fi \(hub.wifi)", rows: [("Receive", Fmt.bps(b.wifi.rx)), ("Send", Fmt.bps(b.wifi.tx)), ("Link", hub.wifiLink)]) }
        Chip(rect: CGRect(x: 820, y: 306, width: 92, height: 70), label: "PMU", sub: Fmt.temp(b.socMax), heat: b.socMax.map { ($0 - 35) / 65 })
            .tip("mac.pmu") { Tip(value: Fmt.temp(b.socMax), label: "Power-management sensors (max)", rows: [("Average", Fmt.temp(b.socAvg))]) }
        // fans
        ForEach(0..<min(2, b.fans.count), id: \.self) { i in
            let fan = b.fans[i]
            FanView(center: CGPoint(x: i == 0 ? 170 : 1010, y: 210), radius: 78, rpm: fan.rpm, heat: fan.max > fan.min ? (fan.rpm - fan.min) / (fan.max - fan.min) : 0)
                .tip("fan\(i)") { Tip(value: "\(Int(fan.rpm)) rpm", label: "Fan \(i + 1)", rows: [("Range", "\(Int(fan.min))–\(Int(fan.max)) rpm")], source: "SMC F\(i)Ac") }
            Text("Fan \(i + 1) · \(Int(fan.rpm)) rpm").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.ink2).position(x: i == 0 ? 170 : 1010, y: 308)
        }
        // battery
        BatteryView(rect: CGRect(x: 205, y: 470, width: 770, height: 285), b: b.battery)
            .tip("mac.battery") {
                let bt = b.battery
                return Tip(value: "\(bt.percent ?? 0)% · \(bt.charging ? "charging" : bt.plugged ? "plugged in" : "on battery")", label: "Battery",
                           rows: [("Into battery", Fmt.w(bt.battW)), ("Adapter in", Fmt.w(bt.sysInW)), ("System load", Fmt.w(bt.sysLoadW)),
                                  ("Voltage / current", bt.volts.map { String(format: "%.2f V / %.2f A", $0, bt.amps ?? 0) } ?? "—"),
                                  ("Temperature", Fmt.temp(bt.tempC)), ("Health", bt.health.map { "\(Fmt.pct($0)) · \(bt.cycles ?? 0) cycles" } ?? "—")],
                           source: "IOKit AppleSmartBattery") }
        // ports, with live state
        PortColumn(names: hub.topo.board.leftPorts, x: 26, side: .leading, ports: b.ports)
        PortColumn(names: hub.topo.board.rightPorts, x: 1154, side: .trailing, ports: b.ports)
        if let p = b.ports.first(where: { $0.sink }) {
            Text("⚡︎ charging through \(p.type == "USB-C" ? "USB-C port \(p.number)" : p.type) · \(p.charger?.chosen.map { "\(Int($0.volts)) V × \($0.amps) A" } ?? "") · \(Fmt.w(b.battery.sysInW)) in")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.power).position(x: 590, y: 790)
        }
    }

    private func avgBusy(_ f: Frame) -> Double { f.chip.cores.values.map(\.busy).reduce(0, +) / Double(max(1, f.chip.cores.count)) }

    private func flows(_ f: Frame) -> [Flow] {
        let c = f.chip, b = f.board
        var out: [Flow] = []
        out.append(Flow(path: line(CGPoint(x: 470, y: 300), CGPoint(x: 505, y: 300)), rd: b.disk.rdBps, wr: b.disk.wrBps, peak: 7e9, offset: CGSize(width: 0, height: 4)))
        out.append(Flow(path: line(CGPoint(x: 695, y: 300), CGPoint(x: 705, y: 300)), rd: c.mem.dramRd, wr: c.mem.dramWr, offset: CGSize(width: 0, height: 4)))
        var w = Path(); w.move(to: CGPoint(x: 820, y: 250)); w.addCurve(to: CGPoint(x: 695, y: 240), control1: CGPoint(x: 790, y: 250), control2: CGPoint(x: 760, y: 200))
        out.append(Flow(path: w, rd: b.wifi.rx, wr: b.wifi.tx, peak: 150e6, offset: CGSize(width: 0, height: 4)))
        out.append(Flow(path: line(CGPoint(x: 600, y: 222), CGPoint(x: 600, y: 76)), rd: c.agentBW("DISP"), wr: 0, peak: 10e9, offset: CGSize(width: 4, height: 0)))
        let inW = (b.battery.sysInW ?? 0) * 1e9
        if let p = b.ports.first(where: { $0.sink }) {
            // Drawn from the label at the bottom: which physical socket a USB-C number is isn't exposed.
            _ = p
            var pp = Path(); pp.move(to: CGPoint(x: 590, y: 776)); pp.addCurve(to: CGPoint(x: 190, y: 560), control1: CGPoint(x: 300, y: 776), control2: CGPoint(x: 180, y: 700))
            pp.addCurve(to: CGPoint(x: 505, y: 360), control1: CGPoint(x: 200, y: 430), control2: CGPoint(x: 360, y: 380))
            out.append(Flow(path: pp, rd: 0, wr: inW, peak: 100e9, offset: .zero, color: (Theme.power, Theme.power)))
        }
        let bw = (b.battery.battW ?? 0)
        out.append(Flow(path: line(CGPoint(x: 590, y: 382), CGPoint(x: 590, y: 470)), rd: bw < 0 ? -bw * 1e9 : 0, wr: bw > 0 ? bw * 1e9 : 0, peak: 100e9, offset: .zero,
                        color: (Theme.power, Theme.power)))
        return out
    }
}

/// The static hardware: chassis, hinge/display, logic board with traces, heat pipe and fin stacks.
/// `temps` (sensor family -> °C) tints the heat pipe and fins on the heat-path page.
struct MacBody: View {
    var f: Frame
    var topo: Topology
    var temps: [String: Double]?
    var body: some View {
        let soc = f.board.socMax
        ZStack(alignment: .topLeading) {
            // display hinge along the top
            RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(hex: 0x2E2F33), Color(hex: 0x1E1F22)], startPoint: .top, endPoint: .bottom))
                .overlay(Text("Display · \(topo.board.display)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2).padding(.leading, 14), alignment: .leading)
                .overlay(heatColor(lin(f.chip.agentBW("DISP"), 10e9)).opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 6)))
                .frame(width: 1100, height: 30).position(x: 590, y: 60)
            Circle().fill(Color(hex: 0x0A0A0B)).overlay(Circle().stroke(Color(hex: 0x3A3B40))).frame(width: 12, height: 12).position(x: 590, y: 60)
            // aluminium bottom case
            RoundedRectangle(cornerRadius: 44)
                .fill(LinearGradient(colors: [Color(hex: 0x2C2D31), Color(hex: 0x1E1F22)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 44).stroke(Color(hex: 0x45464B), lineWidth: 2))
                .frame(width: 1110, height: 700).position(x: 590, y: 430)
            // logic board (PCB) with traces
            LogicBoard().frame(width: 640, height: 300).position(x: 640, y: 270)
            // heat pipe: SoC -> both fin stacks
            HeatPipe(temp: soc).frame(width: 1180, height: 820)
            // fin stacks next to the fans
            FinStack(temp: soc.map { $0 - 6 }).frame(width: 34, height: 150).position(x: 270, y: 210)
            FinStack(temp: soc.map { $0 - 6 }).frame(width: 34, height: 150).position(x: 910 + 0, y: 140)
            // speakers
            ForEach([80.0, 1100.0], id: \.self) { x in SpeakerGrille().frame(width: 52, height: 130).position(x: x, y: 380) }
        }
        .frame(width: 1180, height: 820)
        .allowsHitTesting(false)
    }
}

struct LogicBoard: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Theme.pcb, Color(hex: 0x0A2C21)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, size in
                // deterministic traces + vias
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func rnd() -> CGFloat { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return CGFloat(seed % 10_000) / 10_000 }
                for _ in 0..<90 {
                    var p = Path()
                    var pt = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                    p.move(to: pt)
                    for _ in 0..<3 {
                        if rnd() > 0.5 { pt.x = min(size.width, max(0, pt.x + (rnd() - 0.5) * 160)) } else { pt.y = min(size.height, max(0, pt.y + (rnd() - 0.5) * 120)) }
                        p.addLine(to: pt)
                    }
                    ctx.stroke(p, with: .color(Theme.pcbTrace.opacity(0.55)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3)), with: .color(Color(hex: 0xB89B5E).opacity(0.5)))
                }
            }
            RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x1F5A43), lineWidth: 1.5)
            Text("logic board").font(.system(size: 10)).foregroundStyle(Color(hex: 0x6FA88F)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
        }
    }
}

struct HeatPipe: View {
    var temp: Double?
    var body: some View {
        Canvas { ctx, _ in
            var p = Path()
            p.move(to: CGPoint(x: 600, y: 230)); p.addCurve(to: CGPoint(x: 270, y: 150), control1: CGPoint(x: 500, y: 140), control2: CGPoint(x: 380, y: 150))
            var q = Path()
            q.move(to: CGPoint(x: 640, y: 230)); q.addCurve(to: CGPoint(x: 910, y: 110), control1: CGPoint(x: 720, y: 130), control2: CGPoint(x: 820, y: 110))
            for path in [p, q] {
                ctx.stroke(path, with: .color(Color(hex: 0x5A3A1E)), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                ctx.stroke(path, with: .linearGradient(Gradient(colors: [Theme.copper, Color(hex: 0xD99A5B), Theme.copper]), startPoint: CGPoint(x: 0, y: 100), endPoint: CGPoint(x: 0, y: 260)),
                           style: StrokeStyle(lineWidth: 12, lineCap: .round))
                if let temp { ctx.stroke(path, with: .color(tempColor(temp).opacity(0.55)), style: StrokeStyle(lineWidth: 12, lineCap: .round)) }
            }
        }
    }
}

struct FinStack: View {
    var temp: Double?
    var body: some View {
        Canvas { ctx, size in
            for y in stride(from: CGFloat(0), to: size.height, by: 4) {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(Color(hex: 0x8A8C92).opacity(0.55)))
            }
            if let temp { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tempColor(temp).opacity(0.35))) }
        }
    }
}

struct SpeakerGrille: View {
    var body: some View {
        Canvas { ctx, size in
            for y in stride(from: CGFloat(4), to: size.height, by: 7) {
                for x in stride(from: CGFloat(4) + (Int(y) % 14 == 4 ? 3.5 : 0), to: size.width, by: 7) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 3, height: 3)), with: .color(.black.opacity(0.7)))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x26272A)))
    }
}

/// A board-level chip (black epoxy, silkscreen label), tinted by load.
struct Chip: View {
    var rect: CGRect
    var label: String
    var sub: String
    var heat: Double?
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(hex: 0x1A1A1D), Theme.epoxy], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 4).fill(heatColor(heat)).opacity(heat == nil ? 0 : 0.15 + 0.7 * min(1, heat ?? 0))
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.12))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                Text(sub).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }.padding(8)
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
    }
}

struct Blade: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.midX - r.width * 0.1, y: r.maxY), control: CGPoint(x: r.midX, y: r.midY))
        return p
    }
}

struct BatteryView: View {
    var rect: CGRect
    var b: Battery
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1B1C1E)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x3A3B40)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery").font(.system(size: 13, weight: .semibold))
                Text("\(b.percent ?? 0)% · \(b.charging ? "charging" : b.plugged ? "plugged in" : "on battery") · \(b.battW.map { "\($0 >= 0 ? "into" : "out of") battery \(Fmt.w(abs($0)))" } ?? "")")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink2)
            }.padding(.leading, 18).padding(.top, 12)
            ForEach(0..<6, id: \.self) { i in
                let cell = CGRect(x: 22 + CGFloat(i % 3) * 248, y: 52 + CGFloat(i / 3) * 110, width: 230, height: 96)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(hex: 0x2A2B2F), Color(hex: 0x202124)], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 9).fill(Theme.good.opacity(0.35)).frame(width: max(0, cell.width - 4) * CGFloat(b.percent ?? 0) / 100).padding(2)
                    RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x3A3B40))
                }
                .frame(width: cell.width, height: cell.height).offset(x: cell.minX, y: cell.minY)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
    }
}

struct PortColumn: View {
    var names: [String]
    var x: CGFloat
    var side: HorizontalAlignment
    var ports: [MacPort]
    var body: some View {
        ForEach(Array(names.enumerated()), id: \.offset) { i, name in
            let live = match(name)
            let on = live?.connected ?? false
            let color: Color = !on ? Color(hex: 0x202124) : live?.sink == true ? Color(hex: 0x0A5A0A) : Color(hex: 0x7A5A00)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(color).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15)))
            }
            .frame(width: 26, height: 44).position(x: x, y: 450 + CGFloat(i) * 62)
            .tip("port.\(name)\(i)") {
                Tip(value: live.map { $0.connected ? ($0.sink ? "charging the Mac" : "connected") : "empty" } ?? "USB-C (port number not mapped)",
                    label: name, rows: live.map { p in [("Port", p.id), ("Device", p.vendor ?? "—"), ("Cable", p.cable ?? "—")] } ?? [],
                    explain: "macOS numbers the USB-C ports 1–3; which socket is which number gets confirmed by plugging something in. Every port's live state is on the Ports & power page.",
                    source: "IOKit AppleHPM port controllers")
            }
            Text(name + (on ? " · \(live?.vendor ?? "in use")" : "")).font(.system(size: 10.5)).foregroundStyle(on ? Theme.ink : Theme.muted)
                .frame(width: 160, alignment: side == .leading ? .leading : .trailing)
                .position(x: side == .leading ? x + 100 : x - 100, y: 450 + CGFloat(i) * 62)
        }
    }
    private func match(_ name: String) -> MacPort? {
        switch name {
        case "MagSafe 3": return ports.first { $0.type == "MagSafe 3" }
        case "HDMI": return ports.first { $0.type == "HDMI" }
        case "SDXC card": return ports.first { $0.type == "SD Card" }
        default: return nil   // USB-C sockets: number ↔ position not confirmed yet
        }
    }
}
