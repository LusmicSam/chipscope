import AppKit
import ChipCore
import SwiftUI

@main
struct ChipScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("chipscope", id: "main") {
            RootView()
                .environment(Hub.shared)
                .environment(UIState.shared)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .defaultSize(width: 1480, height: 940)

        MenuBarExtra {
            MenuPanel().environment(Hub.shared).preferredColorScheme(.dark)
        } label: {
            MenuBarLabel().environment(Hub.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Hub.shared.start()
        // macOS may restore the main window hidden (e.g. after a forced quit): always show it on launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.windows.first { $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
        }
        Snapshots.runIfRequested()
    }
    func applicationWillTerminate(_ notification: Notification) { Hub.shared.loads.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum Route: Hashable {
    case mac, soc, cluster(String), core(String), gpu, memory, ports, thermal, atlas, optimize, sensors
}

enum HeatBy: String, CaseIterable, Identifiable {
    case busy = "Busy", work = "Busy × clock", power = "Power"
    var id: String { rawValue }
}

/// Window state. (@State is a macro in this SDK whose plugin ships only with Xcode; state lives here.)
@Observable final class UIState {
    static let shared = UIState()
    var route: Route = .soc
    var heatBy: HeatBy = .busy
    var explain = false
    var inspector = true
    var selection: String?
    var cursor: Int?            // replay index into hub.frames (nil = live)
    var thermalSource: LoadKind = .pCores
    var sensorFilter = ""
    func go(_ r: Route) { route = r; selection = nil }
}

/// Hover card shared by every view: the hovered item's live content and where the pointer is.
@Observable final class Hover {
    static let shared = Hover()
    var tip: (() -> Tip?)?
    var id: String?
    var location: CGPoint = .zero
}

struct Tip {
    var value: String
    var label: String
    var rows: [(String, String)] = []
    var explain: String?
    var source: String?
}
