import Foundation

/// A concrete thing slowing this Mac down, with the evidence and (optionally) a fix.
public struct Finding: Identifiable {
    public enum Severity: Int { case info = 0, warn = 1, high = 2 }
    public enum Action { case kill([Int]), none }
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var memory: Int          // bytes held
    public var cpu: Double          // % of one core
    public var action: Action
    public var actionLabel: String?
}

/// Dev tools that should never outlive their terminal. A process from this list whose parent is
/// launchd (pid 1), running for over an hour, is almost certainly a leftover.
let DEV_TOOLS = ["pytest", "python", "python3", "node", "npm", "jest", "vitest", "uvicorn", "gunicorn", "celery", "go", "cargo", "rustc",
                 "java", "gradle", "ruby", "rails", "make", "webpack", "esbuild", "tsc", "deno", "bun", "swift-frontend", "docker"]

public enum Optimizer {
    public static func analyze(_ procs: [Proc], vm: VMInfo, me: String = NSUserName(), selfPID: Int = Int(getpid())) -> [Finding] {
        var out: [Finding] = []
        let mine = procs.filter { $0.user == me && $0.pid != selfPID }
        // 1. orphaned dev processes (parent gone, still running for > 1 h)
        let orphans = mine.filter { p in
            p.ppid == 1 && p.age > 3600 && (DEV_TOOLS.contains { p.name.lowercased().hasPrefix($0) } || p.path.contains("/.venv/") || p.path.contains("node_modules"))
        }
        if !orphans.isEmpty {
            let mem = orphans.reduce(0) { $0 + $1.rss }, cpu = orphans.reduce(0) { $0 + $1.cpu }
            let names = Dictionary(grouping: orphans, by: \.name).map { "\($0.value.count)× \($0.key)" }.joined(separator: ", ")
            out.append(Finding(id: "orphans", severity: cpu > 20 || mem > 500 << 20 ? .high : .warn,
                               title: "Orphaned dev processes still running",
                               detail: "\(names). Their terminal is gone (parent is launchd) and they have run for \(fmtAge(orphans.map(\.age).max()!)). Usually a test or server left behind.",
                               memory: mem, cpu: cpu, action: .kill(orphans.map(\.pid)), actionLabel: "Stop \(orphans.count)"))
        }
        // 2. runaway CPU (one process pinned for > 10 min)
        for p in mine where p.cpu > 80 && p.age > 600 && !orphans.contains(where: { $0.pid == p.pid }) {
            out.append(Finding(id: "cpu-\(p.pid)", severity: .warn, title: "\(p.name) is using \(Int(p.cpu))% CPU",
                               detail: "Pinned for a while (running \(fmtAge(p.age))). If you are not expecting it, it may be stuck.",
                               memory: p.rss, cpu: p.cpu, action: .kill([p.pid]), actionLabel: "Stop it"))
        }
        // 3. memory by app (helpers grouped)
        let groups = Dictionary(grouping: procs, by: appGroup).map { (k, v) in (k, v.reduce(0) { $0 + $1.rss }, v.count) }
            .sorted { $0.1 > $1.1 }
        for (name, mem, n) in groups.prefix(3) where mem > 1 << 30 {
            out.append(Finding(id: "mem-\(name)", severity: vm.pressure >= 2 ? .warn : .info, title: "\(name) holds \(fmtGB(mem))",
                               detail: "\(n) processes. \(hint(name))", memory: mem, cpu: 0, action: .none, actionLabel: nil))
        }
        // 4. pressure + swap
        if vm.pressure >= 2 || vm.swapUsed > 4 << 30 {
            out.append(Finding(id: "pressure", severity: vm.pressure >= 4 ? .high : .warn,
                               title: vm.pressure >= 2 ? "Memory pressure is \(vm.pressure >= 4 ? "critical" : "elevated")" : "\(fmtGB(vm.swapUsed)) swapped to the SSD",
                               detail: "Swapped pages cost ~100–200 µs each to read back (vs ~0.1 µs in RAM). Compressed now: \(fmtGB(vm.compressed)). Closing the largest apps above is the fix.",
                               memory: vm.swapUsed, cpu: 0, action: .none, actionLabel: nil))
        }
        return out.sorted { ($0.severity.rawValue, $0.memory) > ($1.severity.rawValue, $1.memory) }
    }

    public static func appGroup(_ p: Proc) -> String {
        if p.path.contains("Google Chrome") { return "Google Chrome" }
        if p.path.contains("Visual Studio Code") || p.path.contains("Code Helper") { return "VS Code" }
        if p.path.contains("/claude/versions/") || p.name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil { return "Claude Code" }
        if p.name.hasPrefix("wdav") || p.name == "epsext" { return "Microsoft Defender" }
        if p.path.contains("Slack") { return "Slack" }
        if p.path.contains("Docker") || p.name.contains("Virtualization") { return "Virtual machine" }
        return p.name
    }

    static func hint(_ app: String) -> String {
        switch app {
        case "Google Chrome": return "Chrome's Memory Saver (chrome://settings/performance) unloads idle tabs; Shift+Esc shows which tab is heavy."
        case "Claude Code": return "Each idle session keeps its whole conversation in memory; close sessions you are not using."
        case "Virtual machine": return "A VM reserves memory while it runs; lower its memory limit in its settings."
        case "VS Code": return "Extensions and language servers add up; Help → Open Process Explorer shows them."
        default: return ""
        }
    }
}

public func fmtAge(_ s: Int) -> String { s >= 86400 ? "\(s / 86400) d \(s % 86400 / 3600) h" : s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) m" : "\(s / 60) m" }
public func fmtGB(_ b: Int) -> String { b >= 1 << 30 ? String(format: "%.2f GB", Double(b) / Double(1 << 30)) : "\(b >> 20) MB" }
