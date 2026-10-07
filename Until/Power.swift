import CoreServices
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Holds the one power assertion that keeps the Mac from idle sleep. Display sleep stays with macOS.
final class Assertion {
    private var id: IOPMAssertionID = 0
    private(set) var failed = false

    func hold(_ on: Bool) {
        failed = false
        if on, id == 0 {
            let reason = "Until is keeping the Mac awake while AI agents work" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) != kIOReturnSuccess {
                id = 0
                failed = true
            }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

extension Assertion {
    /// Processes that keep the Mac from sleeping themselves, with their assertion names.
    /// Until's own assertions and media playback are left out.
    static func holders() -> [pid_t: [String]] {
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
              let byProcess = result?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        let sleepTypes: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"]
        let media = ["Playing audio", "Playing video", "Media Playback", "WebRTC", "Video Wake Lock"]
        let me = getpid()
        var holders: [pid_t: [String]] = [:]
        for (pid, list) in byProcess where pid.int32Value != me {
            let names = list.compactMap { a -> String? in
                guard let type = a["AssertType"] as? String, sleepTypes.contains(type) else { return nil }
                let name = a["AssertName"] as? String ?? ""
                return media.contains { name.contains($0) } ? nil : name
            }
            if !names.isEmpty { holders[pid.int32Value] = names }
        }
        return holders
    }
}

struct Battery {
    /// Charge in percent, nil on Macs without a battery.
    var level: Int?
    var onBattery = false

    static func read() -> Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return Battery() }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(level: current * 100 / max, onBattery: d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return Battery()
    }
}

/// Lid-close sleep control through IOPMrootDomain, the public IOKit call Amphetamine uses.
/// Needs no admin rights and works inside the App Sandbox.
enum Clamshell {
    static var isClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    /// Opens a connection and sets the state. Returns the open connection so the
    /// caller can keep it for the whole hold.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool, connection existing: io_connect_t = 0) -> io_connect_t {
        var connect = existing
        if connect == 0 {
            let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            defer { IOObjectRelease(root) }
            guard IOServiceOpen(root, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return 0 }
        }
        var input: UInt64 = disabled ? 1 : 0
        guard IOConnectCallScalarMethod(connect, UInt32(kPMSetClamshellSleepState), &input, 1, nil, nil) == KERN_SUCCESS else {
            IOServiceClose(connect)
            return 0
        }
        return connect
    }

    /// Entry point of the guard child (`Until --lid-guard`). It disables lid-close sleep and
    /// restores it when its stdin closes, which also happens when Until quits or crashes.
    static func runGuard() -> Never {
        let connect = setSleepDisabled(true)
        guard connect != 0 else { exit(1) }

        func restore() -> Never {
            setSleepDisabled(false, connection: connect)
            IOServiceClose(connect)
            exit(0)
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { restore() }
            source.resume()
            signalSources.append(source)
        }
        DispatchQueue.global().async {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            DispatchQueue.main.async { restore() }
        }
        dispatchMain()
    }

    private static var signalSources: [DispatchSourceSignal] = []
}

/// A child process that holds a sleep setting for as long as its stdin pipe stays open.
final class PipeGuard {
    private var process: Process?
    private var pipe: Pipe?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start(_ executable: String, _ arguments: [String]) -> Bool {
        guard process == nil else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.pipe = nil
                self.onExit?(status)
            }
        }
        do { try p.run() } catch { return false }
        process = p
        self.pipe = pipe
        return true
    }

    /// Closes the pipe and waits briefly so the setting is restored before returning.
    func stop() {
        guard let p = process else { return }
        process = nil
        try? pipe?.fileHandleForWriting.close()
        pipe = nil
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { usleep(20_000) }
    }
}

/// What the Mac does once the agents finish, one time: sleep or shut down.
struct Finish {
    enum Action: Int { case asUsual, sleep, shutDown }

    // The wait after the last work, so an agent starting its next step cancels the countdown.
    static let grace: TimeInterval = 60

    // Switching between sleep and shut down keeps a running countdown; arming and disarming restart it.
    var action = Action.asUsual {
        didSet { if action == .asUsual || oldValue == .asUsual { sawWork = false; due = nil } }
    }
    /// When the action runs, set while the countdown is on.
    private(set) var due: Date?
    /// Arming it while nothing works waits for the next work rather than acting right away.
    private var sawWork = false

    /// Returns the action once it is due, then goes back to as usual.
    mutating func update(working: Bool, now: Date) -> Action? {
        guard action != .asUsual else { return nil }
        if working {
            sawWork = true
            due = nil
            return nil
        }
        guard sawWork else { return nil }
        let at = due ?? now.addingTimeInterval(Self.grace)
        guard at <= now else {
            due = at
            return nil
        }
        let ready = action
        action = .asUsual
        return ready
    }

    /// The Apple menu's Sleep or Shut Down. Apps can still stop a shut down, for example to save a document.
    static func run(_ action: Action) -> Bool {
        switch action {
        case .asUsual:
            return true
        case .sleep:
            // Allowed for the logged-in user without a password, also in the App Sandbox.
            let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            defer { IOServiceClose(port) }
            return IOPMSleepSystem(port) == kIOReturnSuccess
        case .shutDown:
            // Without permission the event would raise macOS's prompt and wait for an answer.
            guard shutDownPermission(ask: false) == noErr else { return false }
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEShutDown),
                                               targetDescriptor: loginwindow, returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            return (try? event.sendEvent(options: .noReply, timeout: 10)) != nil
        }
    }

    /// Whether Until may control loginwindow, which shuts down the Mac; asking blocks until the user answers.
    static func shutDownPermission(ask: Bool) -> OSStatus {
        AEDeterminePermissionToAutomateTarget(loginwindow.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEShutDown), ask)
    }

    private static let loginwindow = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
}
