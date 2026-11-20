import ChipCore
import SwiftUI

struct RootView: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared
    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            DetailArea()
        }
        .inspector(isPresented: $ui.inspector) {
            InspectorView().inspectorColumnWidth(min: 290, ideal: 330, max: 440)
        }
    }
}

// ------------------------------------------------------------------ sidebar
struct Sidebar: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared

    private func sidebarRoute(_ r: Route) -> Route {
        if case .core(let id) = r, let (c, _) = hub.topo.core(id) { return .cluster(c.id) }
        return r
    }

    var body: some View {
        let f = hub.latest
        let sel = Binding<Route?>(get: { sidebarRoute(ui.route) }, set: { if let r = $0 { ui.go(r) } })
        List(selection: sel) {
            Section("Machine") {
                row(.mac, "This Mac", "laptopcomputer", f.map { Fmt.w($0.board.battery.sysLoadW) })
                row(.soc, hub.topo.chip.replacingOccurrences(of: "Apple ", with: ""), "cpu", f.map { Fmt.w($0.chip.socW) })
            }
            Section("Compute") {
                ForEach(hub.topo.clusters) { c in
                    row(.cluster(c.id), c.short, c.type == "P" ? "bolt.horizontal" : "leaf", f.map { Fmt.pct($0.chip.clusters[c.id]?.busy) })
                }
                row(.gpu, "GPU", "square.grid.3x3.fill", f.map { Fmt.pct($0.chip.gpu.util ?? $0.chip.gpu.busy) })
            }
            Section("Memory & I/O") {
                row(.memory, "Unified memory", "memorychip", f.map { Fmt.bps($0.chip.mem.dram) })
                row(.ports, "Ports & power", "cable.connector", f.map { b in b.board.ports.filter(\.connected).isEmpty ? "—" : "\(b.board.ports.filter(\.connected).count) in use" })
            }
            Section("Insight") {
                row(.thermal, "Heat paths", "thermometer.medium", f.map { Fmt.temp($0.board.socMax) })
                row(.atlas, "Signal timing", "dot.radiowaves.left.and.right", nil)
                row(.optimize, "Optimize", "wand.and.stars", hub.findings.isEmpty ? nil : "\(hub.findings.count)")
                row(.sensors, "Sensors", "sensor", nil)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ r: Route, _ title: String, _ icon: String, _ metric: String?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let metric { Text(metric).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted) }
        }
        .tag(r)
    }
}

// ------------------------------------------------------------------ detail
struct DetailArea: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ZStack {
                Theme.page
                content.id(routeKey)
                TipOverlay()
            }
            .coordinateSpace(name: "detail")
            .onContinuousHover(coordinateSpace: .named("detail")) { phase in
                if case .active(let p) = phase { Hover.shared.location = p }
            }
            Dock()
        }
        .background(Theme.page)
    }

    private var routeKey: String { "\(ui.route)" }

    @ViewBuilder private var content: some View {
        switch ui.route {
        case .mac: MacView()
        case .soc: SoCView()
        case .cluster(let id): ClusterView(id: id)
        case .core(let id): CoreView(id: id)
        case .gpu: GPUView()
        case .memory: MemoryView()
        case .ports: PortsView()
        case .thermal: ThermalView()
        case .atlas: AtlasView()
        case .optimize: OptimizeView()
        case .sensors: SensorsView()
        }
    }
}

struct HeaderBar: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    Button(c.0) { ui.go(c.1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: i == crumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(i == crumbs.count - 1 ? Theme.ink : Theme.ink2)
                }
            }
            Spacer()
            Picker("Heat by", selection: $ui.heatBy) { ForEach(HeatBy.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 260).labelsHidden()
                .help("What the red means on CPU cores and the GPU")
            Toggle(isOn: $ui.explain) { Label("Explain", systemImage: "text.bubble") }.toggleStyle(.button)
                .help("Hover cards also say what each block is and where its number comes from")
            Button { ui.inspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Inspector")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    private var crumbs: [(String, Route)] {
        let t = hub.topo
        let mac: (String, Route) = ("This Mac", .mac), chip: (String, Route) = (t.chip, .soc)
        switch ui.route {
        case .mac: return [mac]
        case .soc: return [mac, chip]
        case .cluster(let id): return [mac, chip, (t.cluster(id)?.short ?? id, .cluster(id))]
        case .core(let id):
            guard let (c, k) = t.core(id) else { return [mac, chip] }
            return [mac, chip, (c.short, .cluster(c.id)), ("\(c.type)-core \(k.slot)", .core(id))]
        case .gpu: return [mac, chip, ("GPU", .gpu)]
        case .memory: return [mac, chip, ("Unified memory", .memory)]
        case .ports: return [mac, ("Ports & power", .ports)]
        case .thermal: return [mac, ("Heat paths", .thermal)]
        case .atlas: return [("Signal timing", .atlas)]
        case .optimize: return [("Optimize", .optimize)]
        case .sensors: return [("Sensors", .sensors)]
        }
    }
}

// ------------------------------------------------------------------ dock: loads, replay, legend
struct Dock: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("Load").font(.system(size: 11)).foregroundStyle(Theme.muted)
                ForEach(LoadKind.allCases) { k in
                    let on = hub.loadStatus[k]
                    Button { hub.toggleLoad(k) } label: {
                        Text(on.map { "\(k.short) · \(max(0, Int($0.timeIntervalSinceNow)))s" } ?? k.short).font(.system(size: 11)).monospacedDigit().lineLimit(1).fixedSize()
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on != nil ? Color(hex: 0x3A1414) : Theme.page))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on != nil ? Color(hex: 0xF0412B) : Theme.hair))
                    }
                    .buttonStyle(.plain)
                    .help("Run a 20 s \(k.label) load and watch its block light up")
                }
            }
            .fixedSize()
            Button { ui.cursor = nil } label: {
                Label(ui.cursor == nil ? "Live" : "Back to live", systemImage: ui.cursor == nil ? "dot.radiowaves.left.and.right" : "play.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered).tint(ui.cursor == nil ? Theme.good : Theme.warning)
            Timeline()
            HeatLegend()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }
}

struct Timeline: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared
    var body: some View {
        GeometryReader { geo in
            let _ = hub.tick
            let fr = hub.frames
            Canvas { ctx, size in
                guard fr.count > 1 else { return }
                let vals = fr.map { $0.chip.socW + $0.chip.mem.dramW }
                let mx = max(5, vals.max() ?? 5)
                var p = Path()
                for (i, v) in vals.enumerated() {
                    let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(Hub.maxFrames - 1), y: size.height - 3 - (size.height - 6) * CGFloat(v / mx))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                ctx.stroke(p, with: .color(Theme.ink2), lineWidth: 1.3)
                let idx = ui.cursor ?? fr.count - 1
                let x = size.width * CGFloat(idx) / CGFloat(Hub.maxFrames - 1)
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(ui.cursor == nil ? Theme.good : Theme.warning))
            }
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.page))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let i = Int((g.location.x / geo.size.width) * CGFloat(Hub.maxFrames - 1))
                ui.cursor = i >= fr.count - 1 ? nil : max(0, i)
            })
            .help("SoC + DRAM power over the last 5 minutes. Drag to replay.")
            .overlay(alignment: .trailing) {
                let f = hub.current(ui)
                Text(ui.cursor == nil ? "now · \(Fmt.w(f.map { $0.chip.socW + $0.chip.mem.dramW }))" :
                        "\(Int((hub.latest?.t.timeIntervalSince(f?.t ?? Date())) ?? 0)) s ago · \(Fmt.w(f.map { $0.chip.socW + $0.chip.mem.dramW }))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink2).padding(.trailing, 6)
            }
        }
        .frame(height: 30)
    }
}

// ------------------------------------------------------------------ menu bar
struct MenuBarLabel: View {
    @Environment(Hub.self) private var hub
    var body: some View {
        let s = hub.summary
        HStack(spacing: 3) { Image(systemName: "cpu"); Text("\(Int(s.busy * 100))% · \(Fmt.w(s.socW))") }
    }
}

struct MenuPanel: View {
    @Environment(Hub.self) private var hub
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let f = hub.latest
        VStack(alignment: .leading, spacing: 10) {
            Text(hub.topo.chip).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 4) {
                ForEach(hub.topo.liveCores, id: \.1.id) { c, k in
                    RoundedRectangle(cornerRadius: 3).fill(heatColor(f?.chip.cores[k.id]?.busy)).frame(width: 22, height: 30)
                        .overlay(Text(c.type).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)))
                }
            }
            if let f {
                KV(rows: [("SoC power", Fmt.w(f.chip.socW)), ("GPU", Fmt.pct(f.chip.gpu.util ?? f.chip.gpu.busy)), ("DRAM traffic", Fmt.bps(f.chip.mem.dram)),
                          ("Die sensors (max)", Fmt.temp(f.board.socMax)), ("Fans", f.board.fans.map { "\(Int($0.rpm))" }.joined(separator: " / ") + " rpm"),
                          ("Memory pressure", ["", "normal", "warning", "", "critical"][min(4, max(0, f.board.vm.pressure))])])
            }
            Divider()
            Button("Open chipscope") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14).frame(width: 280)
    }
}
