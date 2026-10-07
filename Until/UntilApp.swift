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
        NSApp.mainMenu = Self.keyMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        menu.autoenablesItems = false
        model.onChange = { [weak self] in self?.refresh() }
        refresh()

        // macOS slides the item into place after launch; the pill follows to the menu bar's center.
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSWindow.didMoveNotification, object: item.button?.window)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Opening Until again while it runs, from Finder or Spotlight, shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // Left click turns Until on or off. Right click or control-click opens the menu.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() } else { model.toggle() }
    }

    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func refresh() {
        guard let button = item?.button else { return }
        let label = "\(model.stateTitle). \(model.summary)."
        button.image = statusImage(lift: menuBarLift(of: button))
        button.appearsDisabled = model.isPaused
        button.toolTip = label
        button.setAccessibilityLabel(label)
        if menuOpen, shownMenu != menuSignature { build() }
    }

    /// The working count, the sparkle and the time left on a timed keep-awake, cut out of a pill
    /// the menu bar tints. Every part starts on a whole point so its edges stay sharp on 1x
    /// displays, and SF Mono keeps the width steady as the numbers change.
    private func statusImage(lift: CGFloat) -> NSImage {
        let height = 20.0, gap = 3.0
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

        // The same space around the text on every side.
        let padding = ((height - font.capHeight) / 2).rounded()
        let spark = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage()
        let text = { (string: String?) in string.map { NSAttributedString(string: $0, attributes: [.font: font]) } }
        let count = text(model.workingCount > 0 ? "\(model.workingCount)" : nil), left = text(model.manualRemaining)
        let widths = [count?.size().width, spark.size.width, left?.size().width].compactMap { $0?.rounded(.up) }
        let size = NSSize(width: padding * 2 + widths.reduce(0, +) + gap * Double(widths.count - 1), height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            var x = padding
            if let count {
                count.draw(with: NSRect(x: x, y: padding, width: rect.width, height: 0))
                x += count.size().width.rounded(.up) + gap
            }
            let sparkY = ((height - spark.size.height) / 2).rounded()
            spark.draw(in: NSRect(origin: NSPoint(x: x, y: sparkY), size: spark.size), from: .zero, operation: .destinationOut, fraction: 1)
            x += spark.size.width.rounded(.up) + gap
            left?.draw(with: NSRect(x: x, y: padding, width: rect.width, height: 0))
            return true
        }
        image.isTemplate = true

        // macOS pads a menu bar item by 8 pt on each side and draws the open menu's 24 pt highlight
        // 2 pt past that. Leaving the padding out of the alignment rect lets the 20 pt pill fill the
        // item, 2 pt inside the highlight all around. The lift moves it to the menu bar's center.
        image.alignmentRect = NSRect(x: 8, y: lift, width: size.width - 16, height: height)
        return image
    }

    /// How far the item sits above the menu bar's center, in whole points. macOS 27 centers the
    /// open menu's highlight in the menu bar but the item 1 pt higher.
    private func menuBarLift(of button: NSStatusBarButton) -> CGFloat {
        guard let window = button.window, let screen = window.screen, let superview = button.superview,
              let bar = NSApp.mainMenu?.menuBarHeight, bar > 0 else { return 0 }

        // The layout rect, unlike the frame, ignores the pill's own alignment rect.
        let layout = superview.convert(button.alignmentRect(forFrame: button.frame), to: nil)
        let lift = (window.convertToScreen(layout).midY - (screen.frame.maxY - bar / 2)).rounded()

        // Until macOS places the item, its window sits elsewhere, so only a small lift is real.
        return abs(lift) < bar / 4 ? lift : 0
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
        model.stateTitle + model.summary + "\(model.manualChoice ?? -1)\(model.manualRemaining ?? "")\(model.lidMode)\(model.lidUnavailable)\(model.finish.action)\(model.shutDownBlocked)"
            + model.runs.map { "\($0.id)\($0.working)\($0.title)\(model.ignored.contains($0.id))" }.joined()
    }

    /// Agents shown in the menu itself; the rest go into a submenu, which macOS scrolls when long.
    private static let visibleAgents = 10

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
            for run in model.runs.prefix(Self.visibleAgents) { menu.addItem(agentItem(run)) }
            let rest = model.runs.dropFirst(Self.visibleAgents)
            if !rest.isEmpty {
                let more = NSMenuItem(title: "\(rest.count) more", action: nil, keyEquivalent: "")
                more.submenu = NSMenu()
                for run in rest { more.submenu?.addItem(agentItem(run)) }
                menu.addItem(more)
            }
        }
        menu.addItem(.separator())

        // Timed keep-awake in a submenu; the running choice is checked, choosing it again stops it.
        let awake = NSMenuItem(title: "Stay awake", action: nil, keyEquivalent: "")
        awake.subtitle = model.manualRemaining.map { "\($0) left" }
        awake.submenu = NSMenu()
        for (title, minutes) in [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("Until I turn it off", 0)] {
            if minutes == 0 { awake.submenu?.addItem(.separator()) }
            let entry = action(title, #selector(keepAwake(_:)))
            entry.tag = minutes
            entry.state = model.manualChoice == minutes ? .on : .off
            awake.submenu?.addItem(entry)
        }
        menu.addItem(awake)
        let lid = action("Stay awake when lid is closed", #selector(toggleLid))
        lid.state = model.lidMode ? .on : .off
        lid.subtitle = model.lidUnavailable ? "Not available on this Mac" : nil
        menu.addItem(lid)
        menu.addItem(.separator())

        // Applies once, then goes back to as usual.
        menu.addItem(.sectionHeader(title: "When agents finish"))
        for (title, choice) in [("Sleep as usual", Finish.Action.asUsual), ("Sleep right away", .sleep), ("Shut down", .shutDown)] {
            let entry = action(title, #selector(chooseFinish(_:)))
            entry.tag = choice.rawValue
            entry.state = model.finish.action == choice ? .on : .off
            if choice == .shutDown, model.shutDownBlocked { entry.subtitle = "Allow in System Settings, Automation" }
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        menu.addItem(action("About Until", #selector(showAbout)))
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
    @objc private func keepAwake(_ sender: NSMenuItem) {
        if model.manualChoice == sender.tag { model.stopKeepingAwake() } else { model.keepAwake(minutes: sender.tag) }
    }
    @objc private func toggleLid() { model.lidMode.toggle() }

    @objc private func chooseFinish(_ sender: NSMenuItem) {
        guard let choice = Finish.Action(rawValue: sender.tag) else { return }
        model.chooseFinish(choice)
    }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t, let run = model.runs.first(where: { $0.id == pid }) else { return }
        model.toggleIgnore(run)
    }

    @objc private func showFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Settings

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindow.make(model: model) }
        present { self.settings }
    }

    /// The standard macOS About window, given the app's own icon file: at runtime macOS offers a
    /// single 256 px rendition, which blurs when scaled to About's 64 pt; the file has every size.
    @objc private func showAbout() {
        present {
            let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            NSApp.orderFrontStandardAboutPanel(options: icon.map { [.applicationIcon: $0] } ?? [:])
            return NSApp.windows.first { $0.isVisible && $0.level == .normal && $0 !== self.settings }
        }
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

    /// A menu bar app never shows its main menu, but key equivalents in the settings window
    /// still go through it: Command-W, Command-Q, and editing in the text field.
    private static func keyMenu() -> NSMenu {
        let bar = NSMenu()
        func add(_ items: [NSMenuItem]) {
            let top = NSMenuItem()
            top.submenu = NSMenu()
            items.forEach { top.submenu?.addItem($0) }
            bar.addItem(top)
        }
        func entry(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        add([entry("Close", #selector(NSWindow.performClose(_:)), "w"),
             entry("Quit Until", #selector(NSApplication.terminate(_:)), "q")])
        add([entry("Undo", Selector(("undo:")), "z"),
             entry("Redo", Selector(("redo:")), "z", [.command, .shift]),
             entry("Cut", #selector(NSText.cut(_:)), "x"),
             entry("Copy", #selector(NSText.copy(_:)), "c"),
             entry("Paste", #selector(NSText.paste(_:)), "v"),
             entry("Select All", #selector(NSText.selectAll(_:)), "a")])
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
        case .idle: return finishCountdown.map { "Agents finished, \($0)" } ?? "No agents working"
        case .working: return lidMode ? "\(agents), awake with the lid closed" : "\(agents), Mac stays awake"
        case .manual(let until): return until == .distantFuture ? "Keeping the Mac awake until you stop it" : "Keeping the Mac awake, \(Self.remaining(until)) left"
        case .off: return workingCount > 0 ? "\(agents), Mac may sleep" : "Mac sleeps as usual"
        case .battery(let level): return "Battery at \(level)%, Mac may sleep"
        case .hot: return "Mac is hot and may sleep"
        case .failed: return "macOS declined to keep the Mac awake"
        }
    }

    /// The running countdown, such as "Mac shuts down in 45 s".
    var finishCountdown: String? {
        finish.due.map { "Mac \(finish.action == .sleep ? "sleeps" : "shuts down") in \(Self.remaining($0))" }
    }

    static func remaining(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        return seconds >= 3600 ? "\(seconds / 3600) h \(seconds % 3600 / 60) min"
            : seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}
