import AppKit
import IOKit
import Observation
import OSLog
import ServiceManagement
import UserNotifications

private let log = Logger(subsystem: "com.marcovrinssen.until", category: "status")

/// The real home folder; NSHomeDirectory() points into the container when sandboxed.
let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()

/// One agent process as shown in the menu.
struct AgentRun: Identifiable, Equatable {
    let id: pid_t
    let agent: Agent
    let started: Date
    let directory: String
    let host: String
    var working: Bool
    /// The agent's own name for its task, such as a Claude Code conversation title.
    var task: String?

    var folder: String {
        switch directory {
        case "", "/": ""
        case realHome: "~"
        default: (directory as NSString).lastPathComponent
        }
    }

    /// The task when the agent names it, else the project folder, else the tool.
    var title: String { task ?? (folder.isEmpty ? agent.name : folder) }
}

/// Why Until is or is not keeping the Mac awake right now.
enum Status: Equatable {
    case idle
    case working(Int)
    case manual(until: Date)
    case off
    case battery(Int)
    case hot
    case failed
}

@MainActor
@Observable
final class Model {
    // Settings, persisted in UserDefaults.
    var enabled = Model.load("enabled", true) { didSet { save("enabled", enabled); tick() } }
    var lidMode = Model.load("lidMode", false) { didSet { save("lidMode", lidMode); tick() } }
    var batteryFloor = Model.load("batteryFloor", 20) { didSet { save("batteryFloor", batteryFloor); tick() } }
    var thermalGuard = Model.load("thermalGuard", true) { didSet { save("thermalGuard", thermalGuard); tick() } }
    var notify = Model.load("notify", true) { didSet { save("notify", notify); if notify { requestNotifications() } } }
    var disabledAgents = Set(Model.load("disabledAgents", [String]())) { didSet { save("disabledAgents", Array(disabledAgents)); rescan() } }
    var customAgents = Model.load("customAgents", [String]()) { didSet { save("customAgents", customAgents); rescan() } }

    // Live state.
    private(set) var runs: [AgentRun] = []
    private(set) var status = Status.idle
    private(set) var battery = Battery.read()
    private(set) var manualUntil: Date?
    private(set) var ignored: Set<pid_t> = []
    private(set) var loginItem = SMAppService.mainApp.status == .enabled
    private(set) var claudeAccess = false
    var onChange: (() -> Void)?

    private let tracker = Tracker()
    private let assertion = Assertion()
    private let lidGuard = PipeGuard()
    private var lidHeld = false
    private var timer: Timer?
    private var wasWorking = false
    private var notifiedBattery = false
    private var known: [pid_t: AgentRun] = [:]

    var workingCount: Int { runs.filter { $0.working && !ignored.contains($0.id) }.count }

    init() {
        openClaudeFolder()
        restoreAfterCrash()
        lidGuard.onExit = { [weak self] _ in
            // The guard died on its own; put lid sleep back and let the next tick retry.
            Clamshell.setSleepDisabled(false).release()
            self?.lidHeld = false
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        if notify { requestNotifications() }
        rescan()
    }

    // MARK: Intents

    func toggle() { enabled.toggle() }

    func keepAwake(minutes: Int?) {
        manualUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) } ?? .distantFuture
        if !enabled { enabled = true } else { tick() }
    }

    func stopKeepingAwake() {
        manualUntil = nil
        tick()
    }

    func toggleIgnore(_ run: AgentRun) {
        if ignored.remove(run.id) == nil { ignored.insert(run.id) }
        tick()
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    /// Releases everything before quitting so the Mac never stays awake without Until.
    func shutdown() {
        timer?.invalidate()
        assertion.hold(false)
        releaseLid()
    }

    // MARK: Loop

    func rescan() {
        let now = Date()
        let table = ProcessTable.snapshot()
        let agents = Agent.all.filter { !disabledAgents.contains($0.id) } + customAgents.map(Agent.custom)
        var sightings = Agent.find(in: table, agents: agents)
        var sessions: [pid_t: ClaudeSessions.Session] = [:]
        for i in sightings.indices where sightings[i].agent.id == "claude" {
            let pid = sightings[i].pid
            sessions[pid] = ClaudeSessions.session(pid: pid, started: table[pid]?.start ?? 0)
            sightings[i].status = sessions[pid]?.busy
        }
        let holders = Assertion.holders()
        var working = tracker.update(table: table, sightings: sightings, asserting: Set(holders.keys), now: now.timeIntervalSince1970)
        let apps = Agent.appsWorking(agents: agents, holders: holders, table: table, counted: working)
        working.formUnion(apps.map(\.pid))
        sightings += apps

        var next: [pid_t: AgentRun] = [:]
        for s in sightings {
            let started = Date(timeIntervalSince1970: table[s.pid]?.start ?? now.timeIntervalSince1970)
            // Cached per process; a reused pid with a new start time is a new run.
            var run = known[s.pid].flatMap { $0.started == started ? $0 : nil } ?? AgentRun(
                id: s.pid, agent: s.agent,
                started: started,
                directory: ProcessTable.workingDirectory(s.pid),
                host: Agent.host(of: s.pid, in: table),
                working: false)
            run.working = working.contains(s.pid)
            run.task = sessions[s.pid].flatMap(ClaudeSessions.title(of:))
            next[s.pid] = run
        }
        known = next
        ignored.formIntersection(next.keys)
        runs = next.values.sorted { ($0.working ? 0 : 1, $0.started) < ($1.working ? 0 : 1, $1.started) }
        tick()
    }

    func tick() {
        let now = Date()
        battery = Battery.read()
        if let until = manualUntil, until <= now { manualUntil = nil }

        let count = workingCount
        let manual = manualUntil != nil
        let wanted = count > 0 || manual

        let lowBattery = battery.onBattery && (battery.level ?? 100) <= batteryFloor
        let lidClosed = Clamshell.isClosed
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermalGuard && (thermal == .critical || (lidClosed && thermal == .serious))

        // Only system sleep is held. Display sleep and the sleep timers stay with macOS.
        let hold = enabled && wanted && !lowBattery && !hot
        assertion.hold(hold)
        if hold && lidMode { holdLid() } else { releaseLid() }

        let previous = status
        status = !enabled ? .off
            : lowBattery && wanted ? .battery(battery.level ?? 0)
            : hot && wanted ? .hot
            : assertion.failed ? .failed
            : count > 0 ? .working(count)
            : manual ? .manual(until: manualUntil ?? now)
            : .idle

        if status != previous {
            let names = runs.filter(\.working).map { "\($0.agent.name) \($0.id)" }.joined(separator: ", ")
            log.notice("\(String(describing: self.status), privacy: .public), lid \(self.lidHeld), working: \(names, privacy: .public)")
        }
        notifyTransitions(count: enabled ? count : 0, lowBattery: lowBattery && wanted && enabled)
        onChange?()
    }

    // MARK: Claude Code status

    /// Claude Code's status files live in ~/.claude, outside the App Sandbox container.
    private func openClaudeFolder() {
        #if APPSTORE
        guard let data = UserDefaults.standard.data(forKey: "claudeFolder") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "claudeFolder")
        }
        ClaudeSessions.folder = url.lastPathComponent == ".claude" ? url : url.appendingPathComponent(".claude")
        #else
        ClaudeSessions.folder = URL(fileURLWithPath: realHome).appendingPathComponent(".claude")
        #endif
        claudeAccess = true
    }

    #if APPSTORE
    func grantClaudeAccess() {
        let panel = NSOpenPanel()
        panel.message = "Choose the .claude folder in your home folder so Until can read what Claude Code is working on."
        panel.prompt = "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: realHome).appendingPathComponent(".claude")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: "claudeFolder")
        openClaudeFolder()
        rescan()
    }
    #endif

    // MARK: Lid

    private func holdLid() {
        guard !lidGuard.isRunning, let executable = Bundle.main.executablePath else { return }
        lidHeld = lidGuard.start(executable, ["--lid-guard"])
        UserDefaults.standard.set(lidHeld, forKey: "lidGuardActive")
    }

    /// Restores lid sleep. When the lid is already closed, macOS sleeps right after this.
    private func releaseLid() {
        guard lidGuard.isRunning || lidHeld else { return }
        lidGuard.stop()
        lidHeld = false
        UserDefaults.standard.set(false, forKey: "lidGuardActive")
    }

    /// A guard that was killed outright cannot restore lid sleep itself.
    private func restoreAfterCrash() {
        guard UserDefaults.standard.bool(forKey: "lidGuardActive") else { return }
        Clamshell.setSleepDisabled(false).release()
        UserDefaults.standard.set(false, forKey: "lidGuardActive")
    }

    // MARK: Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notifyTransitions(count: Int, lowBattery: Bool) {
        // Only when nobody is at the Mac; at the desk the count already says it.
        let away = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) > 120
        if wasWorking, count == 0, away { post("Agents finished", "Until will let your Mac sleep.") }
        wasWorking = count > 0
        if lowBattery, !notifiedBattery { post("Until paused", "Battery is at \(battery.level ?? 0)%. Your Mac can sleep now.") }
        notifiedBattery = lowBattery
    }

    private func post(_ title: String, _ body: String) {
        guard notify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Persistence

    private static func load<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

private extension io_connect_t {
    func release() {
        if self != 0 { IOServiceClose(self) }
    }
}
