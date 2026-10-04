import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        if CommandLine.arguments.contains("--lid-guard") { Clamshell.runGuard() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private var model: Model!
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var settings: NSWindow?
    private var menuOpen = false
    private var shownRuns: [AgentRun] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        menu.autoenablesItems = false
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
        // Launch flags for screenshots and manual testing.
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            SettingsView.snapshot(model: model, to: CommandLine.arguments[i + 1])
            NSApp.terminate(nil)
        }
        if CommandLine.arguments.contains("--menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showMenu() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // Same convention as Caffeine and Amphetamine: one click acts, the other opens the menu.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary != model.leftClickShowsMenu { showMenu() } else { model.toggle() }
    }

    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let count = model.workingCount
        switch model.status {
        case .working(let n): button.image = StatusDot.image(count: n, filled: true, dimmed: false)
        case .finishing, .manual: button.image = StatusDot.image(count: nil, filled: true, dimmed: false)
        case .idle, .failed: button.image = StatusDot.image(count: nil, filled: false, dimmed: false)
        case .off, .battery, .hot: button.image = StatusDot.image(count: count > 0 ? count : nil, filled: false, dimmed: true)
        }
        let label = "Until: \(model.headline). \(model.detail)."
        button.toolTip = label
        button.setAccessibilityLabel(label)
        if menuOpen, shownRuns != model.runs { build() } else if menuOpen { header?.rootView = HeaderView(model: model) }
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        build()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    private var header: NSHostingView<HeaderView>?

    private func build() {
        menu.removeAllItems()
        shownRuns = model.runs

        let top = NSMenuItem()
        let view = NSHostingView(rootView: HeaderView(model: model))
        view.frame.size = view.fittingSize
        top.view = view
        header = view
        menu.addItem(top)
        menu.addItem(.separator())

        if model.runs.isEmpty {
            let none = NSMenuItem(title: "No agents running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(.sectionHeader(title: "Agents"))
            for run in model.runs { menu.addItem(agentItem(run)) }
        }
        menu.addItem(.separator())

        if model.manualUntil != nil {
            menu.addItem(action("Stop keeping awake", #selector(stopKeepingAwake)))
        } else {
            let awake = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
            let durations = NSMenu()
            for (title, minutes) in [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240)] {
                let entry = action(title, #selector(keepAwake(_:)))
                entry.tag = minutes
                durations.addItem(entry)
            }
            durations.addItem(.separator())
            durations.addItem(action("Until I turn it off", #selector(keepAwake(_:))))
            awake.submenu = durations
            menu.addItem(awake)
        }
        let lid = action("Stay awake with lid closed", #selector(toggleLid))
        lid.state = model.lidMode ? .on : .off
        menu.addItem(lid)
        menu.addItem(.separator())

        let power = action(model.enabled ? "Turn Until off" : "Turn Until on", #selector(togglePower))
        power.subtitle = model.leftClickShowsMenu ? "Or right-click the dot" : "Or click the dot"
        menu.addItem(power)
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Quit Until", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func agentItem(_ run: AgentRun) -> NSMenuItem {
        let ignored = model.ignored.contains(run.id)
        let entry = NSMenuItem(title: run.agent.name, action: nil, keyEquivalent: "")
        entry.image = AgentDot.image(working: run.working && !ignored)
        // macOS 27 hides menu item images unless asked; the dot carries the agent's state.
        if #available(macOS 27, *) { entry.preferredImageVisibility = .visible }
        let state = ignored ? "ignored" : run.working ? "working" : "quiet"
        entry.subtitle = [run.folder, run.host, state].filter { !$0.isEmpty }.joined(separator: " · ")

        let options = NSMenu()
        let keep = action("Keep awake for this agent", #selector(toggleIgnore(_:)))
        keep.state = ignored ? .off : .on
        keep.representedObject = run.id
        options.addItem(keep)
        if !run.directory.isEmpty {
            let show = action("Show folder in Finder", #selector(showFolder(_:)))
            show.representedObject = run.directory
            options.addItem(show)
        }
        options.addItem(.separator())
        let info = NSMenuItem(title: "Process \(run.id), started \(run.started.formatted(.relative(presentation: .named)))", action: nil, keyEquivalent: "")
        info.isEnabled = false
        options.addItem(info)
        entry.submenu = options
        return entry
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = target ?? self
        return entry
    }

    @objc private func keepAwake(_ sender: NSMenuItem) { model.keepAwake(minutes: sender.tag == 0 ? nil : sender.tag) }
    @objc private func stopKeepingAwake() { model.stopKeepingAwake() }
    @objc private func toggleLid() { model.lidMode.toggle() }
    @objc private func togglePower() { model.toggle() }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t, let run = model.runs.first(where: { $0.id == pid }) else { return }
        model.toggleIgnore(run)
    }

    @objc private func showFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openSettings() {
        if settings == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Until Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }
}

/// The working or quiet marker in front of each agent in the menu.
enum AgentDot {
    static func image(working: Bool) -> NSImage {
        let size: CGFloat = 8
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            if working {
                NSColor.untilAccent.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        return image
    }
}

extension Model {
    var headline: String {
        switch status {
        case .idle: "No agents working"
        case .working(let n): n == 1 ? "1 agent working" : "\(n) agents working"
        case .finishing: "Agents finished"
        case .manual: "Keeping your Mac awake"
        case .off: "Until is off"
        case .battery(let level): "Paused at \(level)% battery"
        case .hot: "Paused, your Mac is hot"
        case .failed: "Could not keep your Mac awake"
        }
    }

    var detail: String {
        switch status {
        case .idle: "Your Mac sleeps as usual"
        case .working: lidMode ? "Awake, also with the lid closed" : "Your Mac stays awake"
        case .finishing(let until): "Sleep allowed in \(Self.remaining(until))"
        case .manual(let until): until == .distantFuture ? "Until you turn it off" : "\(Self.remaining(until)) left"
        case .off: workingCount > 0 ? "\(workingCount) working, sleep allowed" : "Your Mac sleeps as usual"
        case .battery: "Resumes when your Mac charges"
        case .hot: "Resumes when it cools down"
        case .failed: "macOS declined the request"
        }
    }

    static func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        return seconds >= 3600 ? "\(seconds / 3600) h \(seconds % 3600 / 60) min"
            : seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}

/// Status at the top of the menu.
struct HeaderView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.headline)
                .font(.system(size: 13, weight: .semibold))
            Text(model.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 260, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
    }
}
