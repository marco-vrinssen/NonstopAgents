import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Holds one power assertion, such as the one that keeps the Mac from idle sleep.
final class Assertion {
    private let type: String
    private let reason: String
    private var id: IOPMAssertionID = 0
    private(set) var failed = false

    init(_ type: String, reason: String) {
        self.type = type
        self.reason = reason
    }

    func hold(_ on: Bool) {
        failed = false
        if on, id == 0 {
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) != kIOReturnSuccess {
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
    /// The app's own assertions and media playback are left out.
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
    var charging = false
    /// False when macOS reports no readable power state, which makes the lid setting unsafe to hold.
    var known = true

    static func read() -> Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return Battery(known: false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { return Battery(known: false) }
            return Battery(level: current * 100 / max, onBattery: d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                           charging: d[kIOPSIsChargingKey] as? Bool ?? false)
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

    /// Entry point of the guard child (`Nonstop Agents --lid-guard`). It disables lid-close sleep and
    /// restores it when its stdin closes, which also happens when the app quits or crashes.
    static func runGuard() -> Never {
        let connect = setSleepDisabled(true)
        guard connect != 0 else { exit(1) }

        // Tells the app that macOS accepted the setting, so it can say the lid may close.
        FileHandle.standardOutput.write(Data("ready\n".utf8))

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
    var onReady: (() -> Void)?
    /// The child reported that its setting holds.
    private(set) var ready = false

    var isRunning: Bool { process?.isRunning ?? false }

    func start(_ executable: String, _ arguments: [String]) -> Bool {
        guard process == nil else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe(), output = Pipe()
        p.standardInput = pipe
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            handle.readabilityHandler = nil
            guard !handle.availableData.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.ready = true
                self.onReady?()
            }
        }
        p.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.pipe = nil
                self.ready = false
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
        ready = false
        try? pipe?.fileHandleForWriting.close()
        pipe = nil
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { usleep(20_000) }
    }
}

/// Why the lid setting was let go while the lid stayed closed.
enum LidStop: Equatable {
    case time(Int)
    case battery(Int)
}

/// How long the lid has stayed closed while the Mac is kept awake, and how much of that ran on battery.
/// Opening the lid starts over; plugging in pauses the battery time but never resets it.
struct LidStretch {
    private(set) var closed: TimeInterval = 0
    private(set) var onBattery: TimeInterval = 0
    private var last: Date?
    private var lastOnBattery = false

    mutating func update(lidClosed: Bool, held: Bool, battery: Bool, now: Date) {
        guard lidClosed else { self = LidStretch(); return }
        if held, let last {
            let step = now.timeIntervalSince(last)
            closed += step
            // A step that started or ended on battery counts as battery time.
            if battery || lastOnBattery { onBattery += step }
        }
        last = held ? now : nil
        lastOnBattery = battery
    }

    /// The limit reached first, in minutes; 0 means no limit.
    func stop(limit: Int, batteryLimit: Int) -> LidStop? {
        if limit > 0, closed >= TimeInterval(limit * 60) { return .time(limit) }
        if batteryLimit > 0, onBattery >= TimeInterval(batteryLimit * 60) { return .battery(batteryLimit) }
        return nil
    }
}

/// A keep-awake chosen in the menu.
enum KeepAwake: Equatable {
    case indefinitely
    case minutes(Int)
    case until(Date)

    /// The longest keep-awake, 24 hours.
    static let maxMinutes = 24 * 60

    /// The next time the clock shows this time's hour and minute, today or tomorrow.
    static func next(_ time: Date, after now: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? now.addingTimeInterval(24 * 3600)
    }
}
