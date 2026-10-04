import AppKit

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
    private var shownMenu = ""

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
        // Opens a settings tab off-screen without taking focus and prints the window number for screencapture -l.
        if let i = CommandLine.arguments.firstIndex(of: "--settings-preview") {
            openSettings()
            let tab = CommandLine.arguments.dropFirst(i + 1).first.flatMap(Int.init) ?? 0
            (settings?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
            settings?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            print(settings?.windowNumber ?? 0)
            fflush(stdout)
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
        let label = "Until: \(model.headline). \(model.detail)."
        let (symbol, dimmed) = statusSymbol()
        button.image = Self.menuBarImage(symbol, label: label)
        button.appearsDisabled = dimmed
        button.toolTip = label
        if menuOpen, shownMenu != menuSignature { build() }
    }

    /// The dot is an SF Symbol: the numbered circles cut the count out of the fill, and the
    /// system tints them for light and dark menu bars. Filled means the Mac is kept awake.
    private func statusSymbol() -> (name: String, dimmed: Bool) {
        func numbered(_ n: Int, filled: Bool) -> String {
            (n > 50 ? "ellipsis" : "\(n)") + (filled ? ".circle.fill" : ".circle")
        }
        let count = model.workingCount
        switch model.status {
        case .working(let n): return (numbered(n, filled: true), false)
        case .finishing, .manual: return ("circle.fill", false)
        case .idle: return ("circle", false)
        case .failed: return ("exclamationmark.circle", false)
        case .off, .battery, .hot: return (count > 0 ? numbered(count, filled: false) : "circle", true)
        }
    }

    /// The SF Symbol at 15 pt, like the system's own menu bar icons. Symbols lay out on their
    /// text baseline, which crops a circle in the status bar, so it is redrawn into a plain
    /// template image whose bounds are the whole circle.
    private static func menuBarImage(_ name: String, label: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    private var menuSignature: String {
        model.headline + model.detail + model.runs.map { "\($0.id)\($0.working)\(model.ignored.contains($0.id))" }.joined()
            + "\(model.manualUntil != nil)\(model.lidMode)\(model.enabled)"
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        build()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    private func build() {
        menu.removeAllItems()
        shownMenu = menuSignature

        let status = NSMenuItem(title: model.headline, action: nil, keyEquivalent: "")
        status.subtitle = model.detail
        status.isEnabled = false
        menu.addItem(status)
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
        menu.addItem(.separator())
        menu.addItem(action("About Until", #selector(showAbout)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Quit Until", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func agentItem(_ run: AgentRun) -> NSMenuItem {
        let ignored = model.ignored.contains(run.id)
        let entry = NSMenuItem(title: run.agent.name, action: nil, keyEquivalent: "")
        // A filled circle in the system accent color marks a working agent.
        let working = run.working && !ignored
        entry.image = NSImage(systemSymbolName: working ? "circle.fill" : "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [working ? .controlAccentColor : .secondaryLabelColor])))
        // macOS 27 hides menu item images unless asked; this one carries the agent's state.
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

    @objc private func showAbout() {
        present {
            NSApp.orderFrontStandardAboutPanel(nil)
            return NSApp.windows.first { $0.isVisible && $0.level == .normal && $0 !== self.settings }
        }
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindow.make(model: model) }
        if CommandLine.arguments.contains("--settings-preview") {
            settings?.orderFrontRegardless()
        } else {
            present { self.settings }
        }
    }

    /// A menu bar app is not the active app while its menu is used, and macOS may decline to
    /// activate it. Wait for the menu to close, activate, and order the window above all others.
    private func present(_ window: @escaping () -> NSWindow?) {
        DispatchQueue.main.async {
            NSApp.activate()
            guard let shown = window() else { return }
            shown.makeKeyAndOrderFront(nil)
            shown.orderFrontRegardless()
        }
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
