import Darwin
import Foundation

/// One process from the kernel's process table.
struct Proc {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    /// Seconds since 1970.
    let start: TimeInterval
    /// Short kernel name (16 chars), available for every process.
    let comm: String
    /// Executable path, filled for processes of the current user only.
    var path = ""
    /// CPU time in nanoseconds, filled for processes of the current user only.
    var cpu: UInt64 = 0

    var name: String { path.isEmpty ? comm : (path as NSString).lastPathComponent }
}

/// Reads the process table with sysctl and libproc. Both work inside the App Sandbox
/// for processes of the same user; proc_listallpids does not, so it is avoided.
enum ProcessTable {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Every process, or an empty table when the kernel could not be read.
    static func snapshot() -> [pid_t: Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var kinfo: [kinfo_proc] = []
        var size = 0
        // The table can grow between sizing and reading it; ENOMEM means try again.
        for _ in 0..<3 {
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
            kinfo = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
            size = kinfo.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 { break }
            guard errno == ENOMEM else { return [:] }
            size = 0
        }
        guard size > 0 else { return [:] }

        let me = getuid()
        var table: [pid_t: Proc] = [:]
        for k in kinfo.prefix(size / MemoryLayout<kinfo_proc>.stride) where k.kp_proc.p_pid > 0 {
            let started = k.kp_proc.p_un.__p_starttime
            var proc = Proc(
                pid: k.kp_proc.p_pid,
                ppid: k.kp_eproc.e_ppid,
                uid: k.kp_eproc.e_ucred.cr_uid,
                start: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1e6,
                comm: withUnsafeBytes(of: k.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            )
            if proc.uid == me {
                proc.path = path(proc.pid)
                proc.cpu = cpuTime(proc.pid)
            }
            table[proc.pid] = proc
        }
        return table
    }

    static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// PROC_PIDTASKINFO works in the sandbox, proc_pid_rusage does not. It reports Mach
    /// ticks rather than nanoseconds; on Apple Silicon one tick is 41.67 ns.
    static func cpuTime(_ pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return (info.pti_total_user + info.pti_total_system) * timebase.numer / timebase.denom
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }

        // Layout: argc, executable path, NUL padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        var start = i
        while i < size, args.count < argc {
            if buffer[i] == 0 {
                args.append(String(decoding: buffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    static func workingDirectory(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// An agent process found in the table.
struct Sighting {
    let pid: pid_t
    let agent: Agent
    /// A headless run that exits when its task is done, so being alive means working.
    let oneShot: Bool
    /// The agent's own report of whether it is mid-turn, when it publishes one.
    var status: Bool?
}

/// Claude Code reports each session as busy, waiting or idle in ~/.claude/sessions/<pid>.json,
/// and names the conversation in its transcript. Neither is a stable interface, so anything
/// unexpected falls back to the activity heuristic and the folder name.
enum ClaudeSessions {
    struct Session {
        let id: String
        let cwd: String
        /// Busy or not, nil when the status is unknown.
        let busy: Bool?
    }

    /// The ~/.claude folder; inside the App Sandbox only after the user grants access.
    nonisolated(unsafe) static var folder: URL?

    static func session(pid: pid_t, started: TimeInterval) -> Session? {
        guard let url = folder?.appendingPathComponent("sessions/\(pid).json"),
              let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              // A file older than the process belongs to an earlier process with the same pid.
              modified.timeIntervalSince1970 >= started - 2,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["pid"] as? Int == Int(pid),
              let id = json["sessionId"] as? String else { return nil }
        let busy: Bool? = switch json["status"] as? String {
        case "busy": true
        case "idle", "waiting": false
        default: nil
        }
        return Session(id: id, cwd: json["cwd"] as? String ?? "", busy: busy)
    }

    /// The name the user gave the conversation, else the title Claude Code wrote for it.
    /// Returns the last known title right away and refreshes it in the background.
    static func title(of session: Session) -> String? {
        guard let projects = folder?.appendingPathComponent("projects") else { return nil }
        // Claude Code names a project folder after its path, every other character a dash.
        let slug = String(session.cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let transcript = projects.appendingPathComponent("\(slug)/\(session.id).jsonl")
        titleQueue.async { readTitles(transcript, key: session.id) }
        return titles[session.id]
    }

    /// Drops cached titles of sessions that have ended, so a long uptime does not accumulate them.
    static func forget(except live: Set<String>) {
        titles = titles.filter { live.contains($0.key) }
        titleQueue.async { progress = progress.filter { live.contains($0.key) } }
    }

    private static let titleQueue = DispatchQueue(label: "Until.titles", qos: .utility)
    nonisolated(unsafe) private static var titles: [String: String] = [:]
    nonisolated(unsafe) private static var progress: [String: (offset: Int, custom: String?, ai: String?)] = [:]

    /// Reads only the part of the transcript written since the last call. Transcripts reach
    /// tens of megabytes, so the file is memory-mapped and only title lines are parsed.
    private static func readTitles(_ url: URL, key: String) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        var state = progress[key] ?? (0, nil, nil)
        if data.count < state.offset { state = (0, nil, nil) }
        guard data.count > state.offset, let end = data[state.offset...].lastIndex(of: 0x0A) else { return }

        var cursor = state.offset
        while let hit = data.range(of: Data("-title\"".utf8), in: cursor..<end) {
            let start = (data[..<hit.lowerBound].lastIndex(of: 0x0A) ?? -1) + 1
            let stop = data[hit.upperBound...].firstIndex(of: 0x0A) ?? end
            if let line = try? JSONSerialization.jsonObject(with: data[max(start, state.offset)..<stop]) as? [String: Any] {
                if line["type"] as? String == "custom-title", let t = line["customTitle"] as? String { state.custom = t }
                if line["type"] as? String == "ai-title", let t = line["aiTitle"] as? String { state.ai = t }
            }
            cursor = stop
        }
        state.offset = end + 1
        progress[key] = state
        let title = (state.custom ?? state.ai)?.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { titles[key] = title?.isEmpty == false ? title : nil }
    }
}

/// Decides which agents are working from their own status when they publish one,
/// and otherwise from the CPU of their process tree, their tool processes and sleep assertions.
///
/// Measured on Apple Silicon: an agent idling at its prompt uses 0.1 to 0.8 % of a core,
/// an agent streaming a reply or running tools uses 2 to 30 %. Long silent waits on the
/// model are covered by `quietAfter`, silent tool runs by `toolWindow`. Agents that report
/// their own status are released the moment they say they are done.
final class Tracker {
    /// Share of one core above which an agent tree counts as busy.
    var cpuThreshold = 0.02
    /// A descendant this busy counts at any age: long builds, tests, training runs.
    var heavyThreshold = 0.10
    /// A tool process counts this long after it starts, even when silent (sleep, network waits).
    var toolWindow: TimeInterval = 10 * 60
    /// Children started this soon after the agent are its services, such as MCP servers.
    var startupGrace: TimeInterval = 15
    /// Startup work (loading, connecting MCP servers) is not agent work.
    var warmup: TimeInterval = 30
    /// An agent stays working this long after its last sign of work.
    var quietAfter: TimeInterval = 120

    private var previous: [pid_t: (start: TimeInterval, cpu: UInt64)] = [:]
    private var lastSample: TimeInterval?
    private(set) var lastActive: [pid_t: TimeInterval] = [:]

    /// Returns the root pids that are working right now. `asserting` holds the pids that
    /// keep the Mac awake themselves, such as an agent's caffeinate child.
    func update(table: [pid_t: Proc], sightings: [Sighting], asserting: Set<pid_t> = [], now: TimeInterval) -> Set<pid_t> {
        let elapsed = lastSample.map { now - $0 } ?? 0
        let since = lastSample ?? now

        func rate(_ p: Proc) -> Double {
            guard elapsed > 0 else { return 0 }
            var delta: UInt64 = 0
            if let old = previous[p.pid], old.start == p.start {
                delta = p.cpu >= old.cpu ? p.cpu - old.cpu : 0
            } else if p.start >= since {
                delta = p.cpu
            }
            return Double(delta) / 1e9 / elapsed
        }

        var children: [pid_t: [pid_t]] = [:]
        for p in table.values { children[p.ppid, default: []].append(p.pid) }

        var working: Set<pid_t> = []
        for sighting in sightings {
            guard let root = table[sighting.pid] else { continue }
            // An agent's own status wins; only a heavy background job adds to it.
            let precise = sighting.status != nil
            let warm = now - root.start >= warmup
            var busy = sighting.oneShot || sighting.status == true || (!precise && asserting.contains(root.pid))
            var load = warm && !precise ? rate(root) : 0
            var stack = children[root.pid] ?? []
            while let pid = stack.popLast() {
                guard let child = table[pid] else { continue }
                let r = rate(child)
                let isService = child.start - root.start < startupGrace
                if warm && r >= heavyThreshold { busy = true }
                if !precise {
                    if asserting.contains(pid) { busy = true }
                    // Model runtimes keep loaded runners alive; only their CPU counts.
                    if warm && !isService && !sighting.agent.isModel && now - child.start < toolWindow { busy = true }
                    if warm && !isService { load += r }
                }
                stack += children[pid] ?? []
            }
            if load >= cpuThreshold { busy = true }
            if busy { lastActive[root.pid] = now }
            if precise ? busy : lastActive[root.pid].map({ now - $0 < quietAfter }) ?? false {
                working.insert(root.pid)
            }
        }

        let alive = Set(sightings.map(\.pid))
        lastActive = lastActive.filter { alive.contains($0.key) }
        previous = table.mapValues { ($0.start, $0.cpu) }
        lastSample = now
        return working
    }
}
