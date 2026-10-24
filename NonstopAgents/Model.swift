import AppKit
import IOKit
import Observation
import OSLog
import ServiceManagement
import UserNotifications

private let log = Logger(subsystem: "com.marcovrinssen.nonstopagents", category: "status")

/// The real home folder; NSHomeDirectory() points into the container when sandboxed.
let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()

/// One agent process as shown in the menu.
struct AgentRun: Identifiable, Equatable {
    let id: pid_t
    let agent: Agent
    let started: Date
    let directory: String
    let host: String
    /// The app bundle the agent runs in, which Open session brings to the front.
    let app: URL?
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

/// Why Nonstop Agents is or is not keeping the Mac awake right now.
enum Status: Equatable {
    case idle
    case working(Int)
    case manual(until: Date)
    case off
    case battery(Int)
    case unplugged
    case hot
    case failed
}

@MainActor
@Observable
final class Model {
    // Settings, persisted in UserDefaults.
    var enabled = Model.load("enabled", true) { didSet { save("enabled", enabled); tick() } }
    var lidMode = Model.load("lidMode", false) { didSet { save("lidMode", lidMode); lidUnavailable = false; lidStop = nil; tick() } }
    var batteryFloor = min(50, Model.load("batteryFloor", 20)) { didSet { save("batteryFloor", batteryFloor); tick() } }
    var requireCharger = Model.load("requireCharger", false) { didSet { save("requireCharger", requireCharger); tick() } }
    var thermalGuard = Model.load("thermalGuard", true) { didSet { save("thermalGuard", thermalGuard); tick() } }
    var keepDisplayAwake = Model.load("keepDisplayAwake", false) { didSet { save("keepDisplayAwake", keepDisplayAwake); tick() } }
    /// Minutes the lid may stay closed, and stay closed on battery, before the Mac may sleep; 0 means no limit.
    var lidLimit = Model.load("lidLimit", 0) { didSet { save("lidLimit", lidLimit); tick() } }
    var lidBatteryLimit = Model.load("lidBatteryLimit", 0) { didSet { save("lidBatteryLimit", lidBatteryLimit); tick() } }
    /// The last duration chosen with Other duration, in minutes; 0 until one is chosen.
    var lastMinutes = Model.load("lastMinutes", 0) { didSet { save("lastMinutes", lastMinutes) } }
    var notificationsEnabled = Model.load("notificationsEnabled", true) { didSet { save("notificationsEnabled", notificationsEnabled); requestNotifications() } }
    var notifyFinished = Model.load("notifyFinished", true) { didSet { save("notifyFinished", notifyFinished) } }
    var notifyBattery = Model.load("notifyBattery", true) { didSet { save("notifyBattery", notifyBattery) } }
    var notifyHeat = Model.load("notifyHeat", true) { didSet { save("notifyHeat", notifyHeat) } }
    var disabledAgents = Set(Model.load("disabledAgents", [String]())) { didSet { save("disabledAgents", Array(disabledAgents)); rescan() } }
    var customAgents = Model.load("customAgents", [String]()) { didSet { save("customAgents", customAgents); rescan() } }
    /// The welcome window has been shown and closed.
    var onboarded = Model.load("onboarded", false) { didSet { save("onboarded", onboarded) } }

    // Live state.
    private(set) var runs: [AgentRun] = []
    private(set) var status = Status.idle
    private(set) var battery = Battery.read()
    private(set) var manualUntil: Date?
    private(set) var manual: KeepAwake?
    /// The Mac is kept awake right now.
    private(set) var holding = false
    private(set) var lidStop: LidStop?
    /// macOS has notifications for Nonstop Agents turned off.
    private(set) var notificationsDenied = false
    /// macOS refused the lid setting; retried only when lid mode is turned on again.
    private(set) var lidUnavailable = false
    private(set) var loginItem = SMAppService.mainApp.status == .enabled
    private(set) var claudeAccess = false
    var onChange: (() -> Void)?

    private let tracker = Tracker()
    private let assertion = Assertion(kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Nonstop Agents is keeping the Mac awake while AI agents work")
    private let display = Assertion(kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Nonstop Agents is keeping the display on while AI agents work")
    private let lidGuard = PipeGuard()
    private var lidHeld = false
    private var lidStretch = LidStretch()
    private var timer: Timer?
    private var wasWorking = false
    private var notifiedBattery = false
    private var notifiedUnplugged = false
    private var notifiedHeat = false
    private var known: [pid_t: AgentRun] = [:]

    var workingCount: Int { runs.filter(\.working).count }

    /// macOS accepted the lid setting, so closing the lid keeps the Mac awake.
    var lidReady: Bool { lidMode && lidGuard.ready }

    init() {
        openClaudeFolder()
        restoreAfterCrash()
        lidGuard.onExit = { [weak self] status in
            // The guard died on its own; put lid sleep back. A failing status means macOS refused
            // the setting, so stop starting new guards until lid mode is turned on again.
            Clamshell.setSleepDisabled(false).release()
            self?.lidHeld = false
            if status != 0 {
                self?.lidUnavailable = true
                log.error("Lid closed mode unavailable, guard exited with \(status)")
            }
        }
        lidGuard.onReady = { [weak self] in self?.tick() }
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
        rescan()
    }

    // MARK: Intents

    func toggle() { enabled.toggle() }

    func keepAwake(_ choice: KeepAwake) {
        manual = choice
        switch choice {
        case .indefinitely: manualUntil = .distantFuture
        case .minutes(let minutes): manualUntil = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        case .until(let date): manualUntil = date
        }
        if !enabled { enabled = true } else { tick() }
    }

    /// Adds 15 minutes to a timed keep-awake, up to 24 hours from now.
    func extend() {
        guard let until = manualUntil, until != .distantFuture else { return }
        keepAwake(.until(min(until.addingTimeInterval(15 * 60), Date().addingTimeInterval(TimeInterval(KeepAwake.maxMinutes) * 60))))
    }

    func stopKeepingAwake() {
        manualUntil = nil
        manual = nil
        tick()
    }

    /// Time left on a timed keep-awake, such as "29m" or "1h 30m".
    var manualRemaining: String? {
        guard let until = manualUntil, until != .distantFuture else { return nil }
        let minutes = (until.timeIntervalSinceNow / 60).rounded(.up)
        return Self.durationFormatter.string(from: max(60, minutes * 60))
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    /// Releases everything before quitting so the Mac never stays awake without the app.
    func shutdown() {
        timer?.invalidate()
        assertion.hold(false)
        display.hold(false)
        releaseLid()
    }

    // MARK: Loop

    func rescan() {
        let now = Date()
        let table = ProcessTable.snapshot()
        // A failed read is not "no agents": keep the last state rather than let the Mac sleep.
        guard !table.isEmpty else { return }
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
                app: Agent.hostApp(of: s.pid, in: table),
                working: false)
            run.working = working.contains(s.pid)
            run.task = sessions[s.pid].flatMap(ClaudeSessions.title(of:))
            next[s.pid] = run
        }
        known = next
        ClaudeSessions.forget(except: Set(sessions.values.map(\.id)))
        runs = next.values.sorted { ($0.working ? 0 : 1, $0.started) < ($1.working ? 0 : 1, $1.started) }
        tick()
    }

    func tick() {
        let now = Date()
        battery = Battery.read()
        if let until = manualUntil, until <= now {
            manualUntil = nil
            manual = nil
        }

        let count = workingCount
        let manual = manualUntil != nil
        let wanted = count > 0 || manual

        let lidClosed = Clamshell.isClosed
        // With the lid closed the floor also applies on a charger too weak to charge.
        let lowBattery = (battery.level ?? 100) <= batteryFloor && (battery.onBattery || (lidClosed && !battery.charging))
        let unplugged = requireCharger && battery.onBattery
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermalGuard && (thermal == .critical || (lidClosed && thermal == .serious))

        // System sleep is held, and display sleep only when chosen. The sleep timers stay with macOS.
        let hold = enabled && wanted && !lowBattery && !unplugged && !hot
        assertion.hold(hold)
        display.hold(hold && keepDisplayAwake)
        holding = hold && !assertion.failed

        // A lid limit lets go of the lid setting until the lid opens again.
        lidStretch.update(lidClosed: lidClosed, held: lidHeld, battery: battery.onBattery, now: now)
        if !lidClosed { lidStop = nil } else if lidStop == nil { lidStop = lidStretch.stop(limit: lidLimit, batteryLimit: lidBatteryLimit) }
        if hold && lidMode && lidStop == nil && battery.known { holdLid() } else { releaseLid() }

        let previous = status
        status = !enabled ? .off
            : unplugged && wanted ? .unplugged
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
        notifyTransitions(count: enabled ? count : 0, lowBattery: lowBattery && wanted && enabled,
                          unplugged: unplugged && wanted && enabled, hot: hot && wanted && enabled)
        onChange?()
    }

    // MARK: Claude Code status

    /// Claude Code's status files live in ~/.claude, outside the App Sandbox container.
    private func openClaudeFolder() {
        // A read-only sandbox exception opens ~/.claude without asking. If App Review removes it, the folder the user allowed once takes over.
        let home = URL(fileURLWithPath: realHome).appendingPathComponent(".claude")
        if (try? FileManager.default.contentsOfDirectory(atPath: home.path)) != nil {
            ClaudeSessions.folder = home
            claudeAccess = true
            return
        }
        guard let data = UserDefaults.standard.data(forKey: "claudeFolder") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "claudeFolder")
        }
        ClaudeSessions.folder = url.lastPathComponent == ".claude" ? url : url.appendingPathComponent(".claude")
        claudeAccess = true
    }

    func grantClaudeAccess() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the .claude folder in your home folder so Nonstop Agents can read what Claude Code is working on. Access is read-only.")
        panel.prompt = String(localized: "Allow")
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

    // MARK: Lid

    private func holdLid() {
        guard !lidGuard.isRunning, !lidUnavailable, let executable = Bundle.main.executablePath else { return }
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

    /// Asks macOS once for permission, only after the user turned notifications on; after that macOS answers from the user's choice.
    func requestNotifications() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshNotificationStatus() }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            log.notice("Notification permission: \(status.rawValue, privacy: .public)")
            DispatchQueue.main.async { self?.notificationsDenied = status == .denied }
        }
    }

    private func notifyTransitions(count: Int, lowBattery: Bool, unplugged: Bool, hot: Bool) {
        // Only when nobody is at the Mac; at the desk the count already says it.
        let away = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) > 120
        if notifyFinished, wasWorking, count == 0, away { post(String(localized: "Agents finished"), String(localized: "Your Mac can sleep now.")) }
        wasWorking = count > 0
        if notifyBattery, lowBattery, !notifiedBattery { post(String(localized: "Nonstop Agents paused"), String(localized: "Battery is at \(battery.level ?? 0)%. Your Mac can sleep now.")) }
        notifiedBattery = lowBattery
        if notifyBattery, unplugged, !notifiedUnplugged { post(String(localized: "Nonstop Agents paused"), String(localized: "Your Mac is unplugged. It can sleep now.")) }
        notifiedUnplugged = unplugged
        if notifyHeat, hot, !notifiedHeat { post(String(localized: "Nonstop Agents paused"), String(localized: "Your Mac is hot. It can sleep now.")) }
        notifiedHeat = hot
    }

    /// Announces an update found by a background check; the menu offers it too.
    func notifyUpdate(_ version: String) {
        post(String(localized: "Nonstop Agents \(version) is available"), String(localized: "Choose “Update to \(version)…” in the menu to install it."))
    }

    private func post(_ title: String, _ body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Bug reports

    /// Versions, hardware, power and the detected tools for a bug report, without task titles or folders.
    var diagnostics: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let tools = runs.map { "\($0.agent.name) \($0.working ? "working" : "quiet")" }.joined(separator: ", ")
        return """
        Nonstop Agents \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)), \(architecture)
        Status: \(status), on \(enabled), holding \(holding), keep-awake \(manual.map { "\($0)" } ?? "none")
        Lid: mode \(lidMode), closed \(Clamshell.isClosed), ready \(lidReady), unavailable \(lidUnavailable), stop \(lidStop.map { "\($0)" } ?? "none")
        Power: battery \(battery.level.map { "\($0)%" } ?? "none"), on battery \(battery.onBattery), charging \(battery.charging), readable \(battery.known), thermal \(ProcessInfo.processInfo.thermalState.rawValue)
        Settings: floor \(batteryFloor)%, sleep unplugged \(requireCharger), heat guard \(thermalGuard), display \(keepDisplayAwake), lid limit \(lidLimit) min, lid battery limit \(lidBatteryLimit) min
        Claude Code access: \(claudeAccess)
        Agents: \(tools.isEmpty ? "none" : tools)
        """
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
