import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Holds the power assertions that keep the Mac awake.
final class Assertions {
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private(set) var failed = false

    func hold(system wantSystem: Bool, display wantDisplay: Bool) {
        failed = false
        set(&system, kIOPMAssertionTypePreventUserIdleSystemSleep, wantSystem)
        set(&display, kIOPMAssertionTypePreventUserIdleDisplaySleep, wantDisplay)
    }

    private func set(_ id: inout IOPMAssertionID, _ type: String, _ on: Bool) {
        if on, id == 0 {
            let reason = "Until is keeping the Mac awake while AI agents work" as CFString
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) != kIOReturnSuccess {
                id = 0
                failed = true
            }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
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

#if !APPSTORE
/// Optional root helper for the direct edition: `pmset disablesleep` survives charger changes,
/// which the IOKit lid control may not on Apple Silicon. Installed once with an admin password.
enum SleepGuard {
    static let tool = "/Library/PrivilegedHelperTools/com.marcovrinssen.until.sleepguard"
    static let rule = "/etc/sudoers.d/com.marcovrinssen.until"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: tool) && FileManager.default.fileExists(atPath: rule)
    }

    static var sleepDisabled: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    // The guard keeps sleep disabled until Until closes its stdin, quits or crashes.
    // stdin is saved to fd 3 because sh points background jobs at /dev/null.
    private static let script = """
    #!/bin/sh
    exec 3<&0
    restore() { /usr/bin/pmset -a disablesleep 0; exit 0; }
    trap restore HUP INT TERM
    /usr/bin/pmset -a disablesleep 1
    /bin/cat <&3 >/dev/null &
    wait $!
    restore

    """

    static func install() -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("until-install-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: dir.appendingPathComponent("guard"), atomically: true, encoding: .utf8)
            // No arguments allowed: the rule permits exactly this tool and nothing else.
            try "\(NSUserName()) ALL=(root) NOPASSWD: \(tool) \"\"\n"
                .write(to: dir.appendingPathComponent("rule"), atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = dir.path
        return runAsAdmin("""
        /usr/sbin/visudo -cf '\(d)/rule' && /bin/mkdir -p /Library/PrivilegedHelperTools \
        && /usr/bin/install -m 755 -o root -g wheel '\(d)/guard' '\(tool)' \
        && /usr/bin/install -m 440 -o root -g wheel '\(d)/rule' '\(rule)'
        """)
    }

    static func uninstall() -> String? {
        runAsAdmin("/usr/bin/pmset -a disablesleep 0; /bin/rm -f '\(tool)' '\(rule)'")
    }

    /// Shows the standard admin password dialog. Returns an error message, or nil on success.
    private static func runAsAdmin(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return "Cancelled" }
        return error[NSAppleScript.errorMessage] as? String ?? "Could not run as administrator"
    }
}
#endif
