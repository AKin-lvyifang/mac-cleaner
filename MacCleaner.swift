// Mac Cleaner — 菜单栏一键清理：残留进程、闲置 AI 会话、后台 Chrome/飞书重启
// 左键点图标 = 清理；右键 = 查看结果 / 退出
// 命令行：MacCleaner --dry-run（只列出会清理什么，不动手）| --clean（直接清理）

import AppKit
import CoreAudio
import Darwin

// MARK: - 规则参数

let orphanNames: Set<String> = ["node", "python", "python3", "Python", "npx", "npm", "uv", "uvx",
                                "bun", "deno", "tsx", "claude", "codex"]
let orphanMinAge = TimeInterval(ProcessInfo.processInfo.environment["MC_ORPHAN_MIN_AGE"] ?? "") ?? 600  // 孤儿进程至少存在 10 分钟才清
let idleSessionAfter: TimeInterval = 2 * 3600     // AI 会话 2 小时没动静算闲置
let sampleInterval: TimeInterval = 10 * 60
let GB: UInt64 = 1 << 30

struct AppRule { let name: String; let bundleID: String; let limit: UInt64; let args: [String] }
let appRules = [
    AppRule(name: "Chrome", bundleID: "com.google.Chrome", limit: GB * 2, args: ["--restore-last-session"]),
    AppRule(name: "飞书", bundleID: "com.electron.lark", limit: GB * 12 / 10, args: []),
]

// MARK: - 进程信息

struct Proc { let pid: pid_t, ppid: pid_t, uid: uid_t, start: Date, path: String, footprint: UInt64, cpu: UInt64
    var name: String { (path as NSString).lastPathComponent }
}

func allProcs() -> [Proc] {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var out: [Proc] = []
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(got)) where pid > 0 {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        out.append(Proc(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid,
                        start: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
                        path: String(cString: buf), footprint: ok ? ri.ri_phys_footprint : 0,
                        cpu: ok ? ri.ri_user_time + ri.ri_system_time : 0))
    }
    return out
}

func shell(_ cmd: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// launchd 托管的进程（系统/用户服务）一律不碰
func launchdPIDs() -> Set<pid_t> {
    Set(shell("/bin/launchctl", ["list"]).split(separator: "\n").compactMap { pid_t($0.split(separator: "\t").first ?? "") })
}
/// 正在监听端口的进程（本地服务、开发服务器）一律不碰
func listeningPIDs() -> Set<pid_t> {
    Set(shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-t"]).split(separator: "\n").compactMap { pid_t($0) })
}

/// 有程序正在用麦克风 = 可能在开会
func micInUse() -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
    for id in ids {
        var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var ss: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &ss) == noErr, ss > 0 else { continue }
        var r = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0; var rs = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &r, 0, nil, &rs, &running) == noErr, running != 0 { return true }
    }
    return false
}

func pressureLevel() -> Int {   // 1 正常 / 2 紧张 / 4 严重
    var v: Int32 = 0; var s = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &s, nil, 0)
    return Int(v)
}

func fmt(_ b: UInt64) -> String {
    b >= GB ? String(format: "%.1f GB", Double(b) / Double(GB)) : "\(b >> 20) MB"
}

// MARK: - 闲置 AI 会话采样（只看 CPU 时间有没有在涨）

final class IdleTracker {
    private var seen: [pid_t: (cpu: UInt64, since: Date)] = [:]
    static func isSession(_ p: Proc) -> Bool {
        p.name == "claude" && p.path.contains("/Application Support/Claude/claude-code/")
    }
    func sample(_ procs: [Proc]) {
        var next: [pid_t: (UInt64, Date)] = [:]
        for p in procs where Self.isSession(p) {
            if let old = seen[p.pid], old.cpu == p.cpu { next[p.pid] = old } else { next[p.pid] = (p.cpu, Date()) }
        }
        seen = next.mapValues { (cpu: $0.0, since: $0.1) }
    }
    func idle(_ pid: pid_t) -> Bool {
        guard let s = seen[pid] else { return false }
        return Date().timeIntervalSince(s.since) >= idleSessionAfter
    }
}

// MARK: - 清理

struct Line { let text: String; let freed: UInt64 }

final class Cleaner {
    let tracker = IdleTracker()
    let me = getpid()

    func run(dryRun: Bool) -> [Line] {
        let procs = allProcs()
        tracker.sample(procs)
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var kids: [pid_t: [pid_t]] = [:]
        for p in procs { kids[p.ppid, default: []].append(p.pid) }
        func tree(_ pid: pid_t) -> [pid_t] { [pid] + (kids[pid] ?? []).flatMap(tree) }
        let managed = launchdPIDs(), listening = listeningPIDs()
        let uid = getuid(), now = Date()
        var lines: [Line] = []
        var protected: Set<pid_t> = [me]
        var a = byPid[me]?.ppid ?? 0
        while a > 1, let p = byPid[a] { protected.insert(a); a = p.ppid }

        func kill(_ label: String, _ roots: [pid_t]) {
            let pids = Array(Set(roots.flatMap(tree))).filter { !protected.contains($0) && !listening.contains($0) }
            guard !pids.isEmpty else { return }
            let freed = pids.reduce(UInt64(0)) { $0 + (byPid[$1]?.footprint ?? 0) }
            lines.append(Line(text: "\(label) ×\(roots.count)", freed: freed))
            if dryRun { roots.forEach { print("  \(label): \($0) \(byPid[$0]?.path ?? "")") }; return }
            pids.forEach { Darwin.kill($0, SIGTERM) }
            Thread.sleep(forTimeInterval: 2)
            pids.forEach { Darwin.kill($0, SIGKILL) }   // 已退出的会静默失败
        }

        // 1. 残留后台进程：父进程已退出、被系统接管的 node/python/claude 等
        let orphans = procs.filter {
            $0.ppid == 1 && $0.uid == uid && orphanNames.contains($0.name) && !managed.contains($0.pid)
                && !listening.contains($0.pid) && now.timeIntervalSince($0.start) > orphanMinAge
        }.map(\.pid)
        kill("残留后台进程", orphans)

        // 2. 闲置 AI 会话：连同它的 MCP 子进程和外壳进程一起关
        let idle = procs.filter { IdleTracker.isSession($0) && tracker.idle($0.pid) }.map { p -> pid_t in
            if let parent = byPid[p.ppid], parent.name == "disclaimer" { return parent.pid }
            return p.pid
        }
        kill("闲置 AI 会话", idle)

        // 3. 后台占内存大的 Chrome / 飞书：退出后重开（开会时不动）
        let meeting = micInUse()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for rule in appRules where ProcessInfo.processInfo.environment["MC_NO_APPS"] == nil {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: rule.bundleID).first,
                  let url = app.bundleURL else { continue }
            let prefix = url.path + "/"
            let used = procs.filter { $0.path.hasPrefix(prefix) }.reduce(UInt64(0)) { $0 + $1.footprint }
            if used < rule.limit { continue }
            if meeting { lines.append(Line(text: "\(rule.name) 跳过·会议中", freed: 0)); continue }
            if front == rule.bundleID { lines.append(Line(text: "\(rule.name) 跳过·正在用", freed: 0)); continue }
            if dryRun { lines.append(Line(text: "\(rule.name) 重启", freed: used)); continue }
            app.terminate()
            var waited = 0.0
            while !app.isTerminated && waited < 15 { Thread.sleep(forTimeInterval: 0.5); waited += 0.5 }
            guard app.isTerminated else { lines.append(Line(text: "\(rule.name) 未能退出", freed: 0)); continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false; cfg.arguments = rule.args
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            lines.append(Line(text: "\(rule.name) 重启", freed: used))
        }
        return lines
    }
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cleaner = Cleaner()
    var busy = false
    var last: [Line] = []
    var lastTime: Date?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.action = #selector(click)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshIcon() }
        Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { self?.cleaner.tracker.sample(allProcs()) }
        }
        DispatchQueue.global(qos: .utility).async { self.cleaner.tracker.sample(allProcs()) }
    }

    func refreshIcon(_ symbol: String = "memorychip") {
        guard let b = item.button else { return }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mac Cleaner")
        let level = pressureLevel()
        img?.isTemplate = level <= 1
        b.image = level <= 1 ? img
            : img?.withSymbolConfiguration(.init(paletteColors: [level >= 4 ? .systemRed : .systemOrange]))
    }

    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { clean() }
    }

    func clean() {
        guard !busy else { return }
        busy = true
        refreshIcon("arrow.triangle.2.circlepath")
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = self.cleaner.run(dryRun: false)
            DispatchQueue.main.async {
                self.busy = false; self.last = lines; self.lastTime = Date()
                self.refreshIcon()
                let total = lines.reduce(UInt64(0)) { $0 + $1.freed }
                self.item.button?.title = total > 0 ? " −" + fmt(total) : " ✓"
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.item.button?.title = "" }
            }
        }
    }

    func showMenu() {
        let m = NSMenu()
        if let t = lastTime {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let total = last.reduce(UInt64(0)) { $0 + $1.freed }
            m.addItem(withTitle: "\(f.string(from: t))  释放约 \(fmt(total))", action: nil, keyEquivalent: "")
            for l in last { m.addItem(withTitle: "    " + l.text + (l.freed > 0 ? "  " + fmt(l.freed) : ""), action: nil, keyEquivalent: "") }
            if last.isEmpty { m.addItem(withTitle: "    没有可清理的", action: nil, keyEquivalent: "") }
            m.addItem(.separator())
        }
        m.addItem(withTitle: "清理", action: #selector(menuClean), keyEquivalent: "").target = self
        m.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc func menuClean() { clean() }
}

// MARK: - 入口

if CommandLine.arguments.contains("--dry-run") || CommandLine.arguments.contains("--clean") {
    let lines = Cleaner().run(dryRun: CommandLine.arguments.contains("--dry-run"))
    print("麦克风占用(会议): \(micInUse())  内存压力: \(pressureLevel())")
    lines.forEach { print("\($0.text)  \(fmt($0.freed))") }
    if lines.isEmpty { print("没有可清理的") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
