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

    var folder: String {
        switch directory {
        case "", "/": ""
        case realHome: "~"
        default: (directory as NSString).lastPathComponent
        }
    }
}

/// Why Until is or is not keeping the Mac awake right now.
enum Status: Equatable {
    case idle
    case working(Int)
    case finishing(until: Date)
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
    var leftClickShowsMenu = Model.load("leftClickShowsMenu", false) { didSet { save("leftClickShowsMenu", leftClickShowsMenu) } }
    var keepDisplayOn = Model.load("keepDisplayOn", false) { didSet { save("keepDisplayOn", keepDisplayOn); tick() } }
    var holdMinutes = Model.load("holdMinutes", 2) { didSet { save("holdMinutes", holdMinutes); tick() } }
    var lidMode = Model.load("lidMode", false) { didSet { save("lidMode", lidMode); tick() } }
    var batteryFloor = Model.load("batteryFloor", 20) { didSet { save("batteryFloor", batteryFloor); tick() } }
    var thermalGuard = Model.load("thermalGuard", true) { didSet { save("thermalGuard", thermalGuard); tick() } }
    var notify = Model.load("notify", true) { didSet { save("notify", notify); if notify { requestNotifications() } } }
    var disabledAgents = Set(Model.load("disabledAgents", [String]())) { didSet { save("disabledAgents", Array(disabledAgents)); rescan() } }
    var customAgents = Model.load("customAgents", [String]()) { didSet { save("customAgents", customAgents); rescan() } }
    #if !APPSTORE
    var chargerProof = Model.load("chargerProof", false) { didSet { save("chargerProof", chargerProof); sleepGuardFailed = false; tick() } }
    private(set) var sleepGuardFailed = false
    #endif

    // Live state.
    private(set) var runs: [AgentRun] = []
    private(set) var status = Status.idle
    private(set) var holding = false
    private(set) var lidHeld = false
    private(set) var battery = Battery.read()
    private(set) var manualUntil: Date?
    private(set) var ignored: Set<pid_t> = []
    var onChange: (() -> Void)?

    private let tracker = Tracker()
    private let assertions = Assertions()
    private let lidGuard = PipeGuard()
    #if !APPSTORE
    private let sleepGuard = PipeGuard()
    #endif
    private var timer: Timer?
    private var lastWorkAt: Date?
    private var wasWorking = false
    private var notifiedBattery = false
    private var known: [pid_t: AgentRun] = [:]

    private(set) var loginItem = SMAppService.mainApp.status == .enabled
    private(set) var claudeAccess = false

    var workingCount: Int { runs.filter { $0.working && !ignored.contains($0.id) }.count }

    init() {
        openClaudeFolder()
        restoreAfterCrash()
        lidGuard.onExit = { [weak self] _ in
            // The guard died on its own; put lid sleep back and let the next tick retry.
            Clamshell.setSleepDisabled(false).release()
            self?.lidHeld = false
        }
        #if !APPSTORE
        // A guard that exits on its own could not get root (rule missing or changed); stop retrying.
        sleepGuard.onExit = { [weak self] _ in self?.sleepGuardFailed = true }
        #endif
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
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
            NSLog("Until: login item change failed: \(error.localizedDescription)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    /// Releases everything before quitting so the Mac never stays awake without Until.
    func shutdown() {
        timer?.invalidate()
        assertions.hold(system: false, display: false)
        releaseLid()
    }

    // MARK: Loop

    func rescan() {
        let now = Date()
        let table = ProcessTable.snapshot()
        let agents = Agent.all.filter { !disabledAgents.contains($0.id) } + customAgents.map(Agent.custom)
        var sightings = Agent.find(in: table, agents: agents)
        for i in sightings.indices where sightings[i].agent.id == "claude" {
            sightings[i].status = ClaudeSessions.status(pid: sightings[i].pid, started: table[sightings[i].pid]?.start ?? 0)
        }
        let asserting = Assertions.holders()
        var working = tracker.update(table: table, sightings: sightings, asserting: asserting, now: now.timeIntervalSince1970)
        let apps = Agent.appsWorking(agents: agents, asserting: asserting, table: table, counted: working)
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
        if count > 0 { lastWorkAt = now }
        let holdEnd = lastWorkAt.map { $0.addingTimeInterval(TimeInterval(holdMinutes) * 60) }
        let finishing = count == 0 && (holdEnd.map { $0 > now } ?? false)
        let manual = manualUntil != nil
        let wanted = count > 0 || finishing || manual

        let lowBattery = battery.onBattery && (battery.level ?? 100) <= batteryFloor
        let lidClosed = Clamshell.isClosed
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermalGuard && (thermal == .critical || (lidClosed && thermal == .serious))

        let hold = enabled && wanted && !lowBattery && !hot
        assertions.hold(system: hold, display: hold && keepDisplayOn)
        holding = hold && !assertions.failed
        if hold && lidMode { holdLid() } else { releaseLid() }

        let previous = status
        status = !enabled ? .off
            : lowBattery && wanted ? .battery(battery.level ?? 0)
            : hot && wanted ? .hot
            : assertions.failed ? .failed
            : count > 0 ? .working(count)
            : manual ? .manual(until: manualUntil ?? now)
            : finishing ? .finishing(until: holdEnd ?? now)
            : .idle

        if status != previous {
            let names = runs.filter(\.working).map { "\($0.agent.name) \($0.id)" }.joined(separator: ", ")
            log.notice("\(String(describing: self.status), privacy: .public), holding \(self.holding), lid \(self.lidHeld), working: \(names, privacy: .public)")
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
        panel.message = "Choose the .claude folder in your home folder so Until can read whether Claude Code is busy."
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
        if !lidGuard.isRunning, let executable = Bundle.main.executablePath {
            lidHeld = lidGuard.start(executable, ["--lid-guard"])
            UserDefaults.standard.set(lidHeld, forKey: "lidGuardActive")
        }
        #if !APPSTORE
        if chargerProof, SleepGuard.isInstalled, !sleepGuardFailed, !sleepGuard.isRunning {
            let started = sleepGuard.start("/usr/bin/sudo", ["-n", SleepGuard.tool])
            UserDefaults.standard.set(started, forKey: "sleepGuardActive")
        } else if !chargerProof, sleepGuard.isRunning {
            releaseSleepGuard()
        }
        #endif
    }

    /// Restores lid sleep. When the lid is already closed, macOS sleeps right after this.
    private func releaseLid() {
        #if !APPSTORE
        releaseSleepGuard()
        #endif
        guard lidGuard.isRunning || lidHeld else { return }
        lidGuard.stop()
        lidHeld = false
        UserDefaults.standard.set(false, forKey: "lidGuardActive")
    }

    #if !APPSTORE
    private func releaseSleepGuard() {
        guard sleepGuard.isRunning else { return }
        sleepGuard.stop()
        UserDefaults.standard.set(false, forKey: "sleepGuardActive")
    }

    func installSleepGuard() -> String? {
        let error = SleepGuard.install()
        sleepGuardFailed = false
        tick()
        return error
    }

    func uninstallSleepGuard() -> String? {
        releaseSleepGuard()
        let error = SleepGuard.uninstall()
        chargerProof = false
        return error
    }
    #endif

    /// A guard that was killed outright cannot restore lid sleep itself.
    private func restoreAfterCrash() {
        if UserDefaults.standard.bool(forKey: "lidGuardActive") {
            Clamshell.setSleepDisabled(false).release()
            UserDefaults.standard.set(false, forKey: "lidGuardActive")
        }
        #if !APPSTORE
        if UserDefaults.standard.bool(forKey: "sleepGuardActive"), SleepGuard.isInstalled, SleepGuard.sleepDisabled {
            // Starting and stopping the guard runs its restore step.
            if sleepGuard.start("/usr/bin/sudo", ["-n", SleepGuard.tool]) { sleepGuard.stop() }
        }
        UserDefaults.standard.set(false, forKey: "sleepGuardActive")
        #endif
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
        if lowBattery, !notifiedBattery { post("Until paused", "Battery is at \(battery.level ?? 0) %. Your Mac can sleep now.") }
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
