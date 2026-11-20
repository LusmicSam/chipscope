import AppKit
import SwiftUI

/// Animated transport drawn with Core Animation: the dash motion runs in the window server,
/// so the app only touches these layers when a value changes (twice a second), not 15×/s.
struct FlowLayer: NSViewRepresentable {
    var flows: [Flow]
    func makeNSView(context: Context) -> FlowsNSView { FlowsNSView() }
    func updateNSView(_ v: FlowsNSView, context: Context) { v.update(flows) }
}

final class FlowsNSView: NSView {
    override var isFlipped: Bool { true }
    private var lanes: [CAShapeLayer] = []
    private var speeds: [Double] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the blocks underneath

    func update(_ flows: [Flow]) {
        guard let root = layer else { return }
        let needed = flows.count * 2
        while lanes.count < needed {
            let l = CAShapeLayer()
            l.fillColor = nil; l.lineCap = .round; l.lineDashPattern = [3, 9]
            root.addSublayer(l); lanes.append(l); speeds.append(0)
        }
        while lanes.count > needed { lanes.removeLast().removeFromSuperlayer(); speeds.removeLast() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, f) in flows.enumerated() {
            let lanesSpec: [(Double, Double, Color, CGSize)] = [(f.wr, 1, f.color.1, f.offset), (f.rd, -1, f.color.0, CGSize(width: -f.offset.width, height: -f.offset.height))]
            for (j, spec) in lanesSpec.enumerated() {
                let k = i * 2 + j, l = lanes[k]
                let (v, dir, color, off) = spec
                let x = logBW(v, f.peak)
                let path = f.path.applying(CGAffineTransform(translationX: off.width, y: off.height)).cgPath
                if l.path != path { l.path = path }
                guard x > 0.02 else {
                    l.isHidden = true
                    if speeds[k] != 0 { l.removeAnimation(forKey: "dash"); speeds[k] = 0 }
                    continue
                }
                l.isHidden = false
                l.strokeColor = NSColor(color).withAlphaComponent(0.35 + 0.65 * x).cgColor
                l.lineWidth = 1.2 + 8 * x
                let speed = (12 + 140 * x) * dir                 // px per second along the path
                if speeds[k] == 0 || abs(speed - speeds[k]) > abs(speeds[k]) * 0.2 {
                    let a = CABasicAnimation(keyPath: "lineDashPhase")
                    a.fromValue = 0; a.toValue = -12 * dir      // one dash period
                    a.duration = 12 / abs(speed)
                    a.repeatCount = .infinity
                    l.add(a, forKey: "dash")
                    speeds[k] = speed
                }
            }
        }
        CATransaction.commit()
    }
}

/// A cooling fan whose blades spin in Core Animation at the measured RPM (shown 50× slower, so it reads).
struct FanView: View {
    var center: CGPoint
    var radius: CGFloat
    var rpm: Double
    var heat: Double
    var body: some View {
        FanLayer(radius: radius, rpm: rpm, heat: heat)
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
            .position(center)
    }
}

struct FanLayer: NSViewRepresentable {
    var radius: CGFloat
    var rpm: Double
    var heat: Double
    func makeNSView(context: Context) -> FanNSView { FanNSView(radius: radius) }
    func updateNSView(_ v: FanNSView, context: Context) { v.update(rpm: rpm, heat: heat) }
}

final class FanNSView: NSView {
    private let tint = CAShapeLayer(), blades = CAShapeLayer()
    private var lastRPM = -1.0
    init(radius r: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: r * 2, height: r * 2))
        wantsLayer = true
        layer = CALayer()
        let box = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        let base = CAShapeLayer(); base.path = CGPath(ellipseIn: box, transform: nil); base.fillColor = NSColor(Color(hex: 0x18191B)).cgColor
        base.strokeColor = NSColor(Color(hex: 0x3A3B40)).cgColor; base.lineWidth = 2
        tint.path = base.path
        blades.frame = box
        let one = Blade().path(in: CGRect(x: -r * 0.21, y: -r * 0.9, width: r * 0.42, height: r * 0.9))
        var all = Path()
        for k in 0..<11 { all.addPath(one.applying(CGAffineTransform(rotationAngle: CGFloat(k) * .pi * 2 / 11).concatenating(CGAffineTransform(translationX: r, y: r)))) }
        blades.path = all.cgPath; blades.fillColor = NSColor(Color(hex: 0x55565C)).cgColor
        let hub = CAShapeLayer(); hub.path = CGPath(ellipseIn: box.insetBy(dx: r * 0.79, dy: r * 0.79), transform: nil); hub.fillColor = NSColor(Color(hex: 0x2C2D31)).cgColor
        for l in [base, tint, blades, hub] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(rpm: Double, heat: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.fillColor = NSColor(heatColor(heat)).withAlphaComponent(0.25 + 0.5 * heat).cgColor
        CATransaction.commit()
        guard abs(rpm - lastRPM) > max(30, lastRPM * 0.05) else { return }
        lastRPM = rpm
        blades.removeAnimation(forKey: "spin")
        guard rpm > 1 else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0; a.toValue = -Double.pi * 2
        a.duration = 60 / rpm * 50
        a.repeatCount = .infinity
        blades.add(a, forKey: "spin")
    }
}
