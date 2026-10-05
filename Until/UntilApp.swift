import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
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
        NSApp.mainMenu = Self.mainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            // SF Mono, so the count keeps its width as it changes.
            button.font = .monospacedSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        menu.delegate = self
        menu.autoenablesItems = false
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// The Dock icon shows while settings are open; clicking it brings them back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // Left click opens settings. Right click or control-click opens the menu with the controls.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() } else { openSettings() }
    }

    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let count = model.workingCount
        let label = "\(model.stateTitle). \(model.summary)."
        button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Until")
        button.title = count > 0 ? String(count) : ""
        button.appearsDisabled = model.isPaused
        button.toolTip = label
        button.setAccessibilityLabel(label)
        if menuOpen, shownMenu != menuSignature { build() }
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        build()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    private var menuSignature: String {
        model.stateTitle + model.summary + "\(model.manualUntil != nil)\(model.lidMode)"
            + model.runs.map { "\($0.id)\($0.working)\($0.title)\(model.ignored.contains($0.id))" }.joined()
    }

    private func build() {
        menu.removeAllItems()
        shownMenu = menuSignature

        // The switch comes first, with a status dot so the state reads without the menu bar.
        let power = action(model.stateTitle, #selector(togglePower))
        power.subtitle = model.summary
        power.image = NSImage(named: model.statusDot)
        // macOS 27 hides menu item images unless asked; this one is the state.
        if #available(macOS 27, *) { power.preferredImageVisibility = .visible }
        menu.addItem(power)
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

        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Quit Until", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func agentItem(_ run: AgentRun) -> NSMenuItem {
        let ignored = model.ignored.contains(run.id)
        let entry = NSMenuItem(title: run.title, action: nil, keyEquivalent: "")
        let tool = run.title == run.agent.name ? "" : run.agent.name
        let folder = run.title == run.folder ? "" : run.folder
        let state = ignored ? "ignored" : run.working ? "working" : "quiet"
        entry.subtitle = [tool, folder, state].filter { !$0.isEmpty }.joined(separator: " · ")

        let options = NSMenu()
        let keep = action("Keep awake for this agent", #selector(toggleIgnore(_:)))
        keep.state = ignored ? .off : .on
        keep.representedObject = run.id
        options.addItem(keep)
        if !run.directory.isEmpty, run.directory != "/" {
            let show = action("Show folder in Finder", #selector(showFolder(_:)))
            show.representedObject = run.directory
            options.addItem(show)
        }
        options.addItem(.separator())
        let place = run.host.isEmpty ? "" : " in \(run.host)"
        let info = NSMenuItem(title: "Process \(run.id)\(place), started \(run.started.formatted(.relative(presentation: .named)))",
                              action: nil, keyEquivalent: "")
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

    @objc private func togglePower() { model.toggle() }
    @objc private func keepAwake(_ sender: NSMenuItem) { model.keepAwake(minutes: sender.tag == 0 ? nil : sender.tag) }
    @objc private func stopKeepingAwake() { model.stopKeepingAwake() }
    @objc private func toggleLid() { model.lidMode.toggle() }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t, let run = model.runs.first(where: { $0.id == pid }) else { return }
        model.toggleIgnore(run)
    }

    @objc private func showFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Settings

    @objc private func openSettings() { showSettings(tab: nil) }
    @objc private func openAbout() { showSettings(tab: SettingsWindow.aboutTab) }

    private func showSettings(tab: Int?) {
        if settings == nil {
            settings = SettingsWindow.make(model: model)
            settings?.delegate = self
        }
        if let tab { (settings?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab }
        // A regular app while settings are open, so they are in the Dock and in Command-Tab.
        NSApp.setActivationPolicy(.regular)
        present { self.settings }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settings else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// A menu bar app is not the active app when its icon is clicked, and macOS may decline to
    /// activate it. Wait for the click to finish, ask to activate, and order the window to the front
    /// even when macOS keeps the focus elsewhere; one click then focuses it.
    private func present(_ window: @escaping () -> NSWindow?) {
        DispatchQueue.main.async {
            NSApp.activate()
            guard let shown = window() else { return }
            shown.makeKeyAndOrderFront(nil)
            shown.orderFrontRegardless()
        }
    }

    /// The standard menus, shown while settings are in front: About, Settings, Hide and Quit,
    /// Close, editing for the text field, and the Window menu.
    private static func mainMenu() -> NSMenu {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = submenu
            bar.addItem(top)
            return submenu
        }
        func entry(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        _ = add("Until", [
            entry("About Until", #selector(AppDelegate.openAbout)),
            .separator(),
            entry("Settings…", #selector(AppDelegate.openSettings), ","),
            .separator(),
            entry("Hide Until", #selector(NSApplication.hide(_:)), "h"),
            entry("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            entry("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            entry("Quit Until", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("File", [entry("Close", #selector(NSWindow.performClose(_:)), "w")])
        _ = add("Edit", [
            entry("Undo", Selector(("undo:")), "z"),
            entry("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            entry("Cut", #selector(NSText.cut(_:)), "x"),
            entry("Copy", #selector(NSText.copy(_:)), "c"),
            entry("Paste", #selector(NSText.paste(_:)), "v"),
            entry("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        NSApp.windowsMenu = add("Window", [
            entry("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            entry("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        return bar
    }
}

extension Model {
    /// Off, or on but held back by battery or heat.
    var isPaused: Bool {
        switch status {
        case .off, .battery, .hot: true
        default: false
        }
    }

    var stateTitle: String {
        switch status {
        case .off: "Until is off"
        case .battery, .hot: "Until is paused"
        default: "Until is on"
        }
    }

    /// Green when on, yellow when paused or failing, gray when off. Stock AppKit status images.
    var statusDot: NSImage.Name {
        switch status {
        case .off: NSImage.statusNoneName
        case .battery, .hot, .failed: NSImage.statusPartiallyAvailableName
        default: NSImage.statusAvailableName
        }
    }

    var summary: String {
        let agents = workingCount == 1 ? "1 agent working" : "\(workingCount) agents working"
        switch status {
        case .idle: return "No agents working"
        case .working: return lidMode ? "\(agents), awake with the lid closed" : "\(agents), Mac stays awake"
        case .manual(let until): return until == .distantFuture ? "Keeping the Mac awake until you stop it" : "Keeping the Mac awake, \(Self.remaining(until)) left"
        case .off: return workingCount > 0 ? "\(agents), Mac may sleep" : "Mac sleeps as usual"
        case .battery(let level): return "Battery at \(level)%, Mac may sleep"
        case .hot: return "Mac is hot and may sleep"
        case .failed: return "macOS declined to keep the Mac awake"
        }
    }

    static func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        return seconds >= 3600 ? "\(seconds / 3600) h \(seconds % 3600 / 60) min"
            : seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}
