import AppKit
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
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
    private var welcome: NSWindow?
    private var updater: SPUStandardUpdaterController!
    private var updateOptions: UpdateOptions?
    /// A version found by a background check, offered in the menu until the user looks at it.
    private var availableUpdate: String?
    /// Sparkle's relaunch into a new version, held back while the Mac is kept awake.
    private var pendingInstall: (() -> Void)?
    private var menuOpen = false
    private var shownMenu = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
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
        if !model.onboarded { showWelcome() }
    }

    /// Shown once. Closing it, with Get started or the close button, counts as seen.
    private func showWelcome() {
        let window = WelcomeWindow.make(model: model)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.onboarded = true
                self?.welcome = nil
            }
        }
        welcome = window
        present { window }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Opening Nonstop Agents again while it runs, from Finder or Spotlight, shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // Left click turns Nonstop Agents on or off. Right click or control-click opens the menu.
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
        if let install = pendingInstall, !model.holding {
            pendingInstall = nil
            install()
        }
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

        // The lift moves the pill inside a taller image, since macOS clips an image to its alignment rect.
        let size = NSSize(width: padding * 2 + widths.reduce(0, +) + gap * Double(widths.count - 1), height: height + 2 * abs(lift))
        let bottom = abs(lift) - lift

        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: NSRect(x: 0, y: bottom, width: rect.width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            var x = padding
            if let count {
                count.draw(with: NSRect(x: x, y: bottom + padding, width: rect.width, height: 0))
                x += count.size().width.rounded(.up) + gap
            }
            let sparkY = bottom + ((height - spark.size.height) / 2).rounded()
            spark.draw(in: NSRect(origin: NSPoint(x: x, y: sparkY), size: spark.size), from: .zero, operation: .destinationOut, fraction: 1)
            x += spark.size.width.rounded(.up) + gap
            left?.draw(with: NSRect(x: x, y: bottom + padding, width: rect.width, height: 0))
            return true
        }
        image.isTemplate = true

        // macOS pads a menu bar item by 8 pt on each side and draws the open menu's 24 pt highlight
        // 2 pt past that. Leaving the padding out of the alignment rect lets the 20 pt pill fill the
        // item, 2 pt inside the highlight all around.
        image.alignmentRect = NSRect(x: 8, y: 0, width: size.width - 16, height: size.height)
        return image
    }

    /// How far the item sits above its menu bar's center in whole points, 1 on an external display.
    private func menuBarLift(of button: NSStatusBarButton) -> CGFloat {
        guard let window = button.window, let superview = button.superview else { return 0 }

        // The layout rect, unlike the frame, ignores the pill's own alignment rect.
        let layout = superview.convert(button.alignmentRect(forFrame: button.frame), to: nil)

        // The status window spans the menu bar of its own display, unlike the app-wide menu bar height.
        let lift = (layout.midY - window.frame.height / 2).rounded()

        // Until macOS places the item, its window has no menu bar around it, so only a small lift is real.
        return abs(lift) < window.frame.height / 4 ? lift : 0
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
        model.stateTitle + model.summary + "\(String(describing: model.manual))\(model.manualRemaining ?? "")\(model.lidMode)\(model.lidSubtitle ?? "")"
            + "\(model.claudeAccess)\(availableUpdate ?? "")\(pendingInstall == nil)"
            + model.runs.map { "\($0.id)\($0.working)\($0.title)" }.joined()
    }

    /// Agents shown in the menu itself; the rest go into a submenu, which macOS scrolls when long.
    private static let visibleAgents = 10

    private func build() {
        menu.removeAllItems()
        shownMenu = menuSignature

        // The switch comes first. A stock status dot in its state column marks on and paused.
        let power = action(model.switchTitle, #selector(togglePower))
        power.state = model.powerState
        power.onStateImage = NSImage(named: NSImage.statusAvailableName)
        power.mixedStateImage = NSImage(named: NSImage.statusPartiallyAvailableName)
        power.subtitle = model.pauseReason
        menu.addItem(power)
        menu.addItem(.separator())

        if model.runs.isEmpty {
            let none = NSMenuItem(title: String(localized: "No agents running"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(.sectionHeader(title: String(localized: "Agents")))
            for run in model.runs.prefix(Self.visibleAgents) { menu.addItem(agentItem(run)) }
            let rest = model.runs.dropFirst(Self.visibleAgents)
            if !rest.isEmpty {
                let more = NSMenuItem(title: String(localized: "\(rest.count) more"), action: nil, keyEquivalent: "")
                more.submenu = NSMenu()
                for run in rest { more.submenu?.addItem(agentItem(run)) }
                menu.addItem(more)
            }

            // Without ~/.claude, Claude Code's state is a guess from CPU use, so the menu asks once.
            if !model.claudeAccess, model.runs.contains(where: { $0.agent.id == "claude" }) {
                menu.addItem(action(String(localized: "Allow access to Claude Code…"), #selector(allowClaudeAccess)))
            }
        }
        menu.addItem(.separator())

        // The running keep-awake is checked, and choosing it again stops it. Tag 0 means until turned off.
        menu.addItem(.sectionHeader(title: String(localized: "Stay awake")))
        let always = action(String(localized: "Indefinitely"), #selector(keepAwake(_:)))
        always.tag = 0
        always.state = model.manual == .indefinitely ? .on : .off
        menu.addItem(always)
        menu.addItem(timedItem())
        let lid = action(String(localized: "With lid closed"), #selector(toggleLid))
        lid.state = model.lidMode ? .on : .off
        lid.subtitle = model.lidSubtitle
        menu.addItem(lid)
        menu.addItem(.separator())

        menu.addItem(action(String(localized: "About Nonstop Agents"), #selector(showAbout)))
        if pendingInstall != nil {
            let waiting = NSMenuItem(title: String(localized: "Update installs when your Mac may sleep"), action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
        } else {
            let update = availableUpdate.map { String(localized: "Update to \($0)…") } ?? String(localized: "Check for updates…")
            menu.addItem(action(update, #selector(checkForUpdates)))
        }
        let settings = action(String(localized: "Settings"), #selector(openSettings), key: ",")
        // macOS 27 adds a gear to Settings, which would push its title out of line with the others.
        if #available(macOS 27, *) { settings.preferredImageVisibility = .hidden }
        menu.addItem(settings)
        menu.addItem(action(String(localized: "Quit Nonstop Agents"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    /// "For a while": the preset durations plus the last one chosen, then a running timer's extension and the custom choices.
    private func timedItem() -> NSMenuItem {
        let timed = NSMenuItem(title: String(localized: "For a while"), action: nil, keyEquivalent: "")
        timed.subtitle = model.manualRemaining.map { String(localized: "\($0) left") }
        switch model.manual {
        case .minutes, .until: timed.state = .on
        default: timed.state = .off
        }
        let options = NSMenu()
        for minutes in Set([15, 30, 60, 120, 240, model.lastMinutes]).filter({ $0 > 0 }).sorted() {
            let entry = action(Model.duration(minutes), #selector(keepAwake(_:)))
            entry.tag = minutes
            entry.state = model.manual == .minutes(minutes) ? .on : .off
            options.addItem(entry)
        }
        options.addItem(.separator())
        if model.manualRemaining != nil {
            options.addItem(action(String(localized: "Add 15 minutes"), #selector(extend)))
            options.addItem(action(String(localized: "Stop timer"), #selector(stopTimer)))
        }
        options.addItem(action(String(localized: "Other duration…"), #selector(chooseDuration)))
        let until = action(String(localized: "Until a time…"), #selector(chooseTime))
        if case .until(let end) = model.manual {
            until.state = .on
            until.subtitle = end.formatted(date: .omitted, time: .shortened)
        }
        options.addItem(until)
        timed.submenu = options
        return timed
    }

    private func agentItem(_ run: AgentRun) -> NSMenuItem {
        let entry = NSMenuItem(title: run.title, action: nil, keyEquivalent: "")
        let tool = run.title == run.agent.name ? "" : run.agent.name
        let folder = run.title == run.folder ? "" : run.folder
        entry.subtitle = [tool, folder, run.working ? String(localized: "working", comment: "An agent's state in the menu") : String(localized: "quiet", comment: "An agent's state in the menu")].filter { !$0.isEmpty }.joined(separator: " · ")

        // The same stock green dot as the switch marks each agent that keeps the Mac awake right now.
        entry.state = run.working ? .on : .off
        entry.onStateImage = NSImage(named: NSImage.statusAvailableName)

        let options = NSMenu()
        if !run.directory.isEmpty, run.directory != "/" {
            let folderItem = action(String(localized: "Open folder"), #selector(openFolder(_:)))
            folderItem.representedObject = run.directory
            options.addItem(folderItem)
        }
        if let app = run.app {
            let sessionItem = action(String(localized: "Open session"), #selector(openSession(_:)))
            sessionItem.representedObject = app
            options.addItem(sessionItem)
        }
        if !options.items.isEmpty { options.addItem(.separator()) }
        let pid = String(run.id), started = run.started.formatted(.relative(presentation: .named))
        let details = run.host.isEmpty ? String(localized: "Process \(pid), started \(started)")
            : String(localized: "Process \(pid) in \(run.host), started \(started)")
        let info = NSMenuItem(title: details, action: nil, keyEquivalent: "")
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
        let choice: KeepAwake = sender.tag == 0 ? .indefinitely : .minutes(sender.tag)
        if model.manual == choice { model.stopKeepingAwake() } else { model.keepAwake(choice) }
    }
    @objc private func extend() { model.extend() }
    @objc private func stopTimer() { model.stopKeepingAwake() }

    /// Asks for a duration from 1 minute to 24 hours, starting from the last one chosen.
    @objc private func chooseDuration() {
        let start = model.lastMinutes > 0 ? model.lastMinutes : 45
        let hours = NSTextField(string: String(start / 60)), minutes = NSTextField(string: String(start % 60))
        for field in [hours, minutes] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        let row = NSStackView(views: [hours, NSTextField(labelWithString: String(localized: "hours")),
                                      minutes, NSTextField(labelWithString: String(localized: "minutes"))])
        row.setFrameSize(row.fittingSize)
        guard ask(String(localized: "Keep the Mac awake for"), String(localized: "From 1 minute to 24 hours."), row, focus: hours) else { return }
        let h = min(max(Int(hours.stringValue) ?? 0, 0), 24), m = min(max(Int(minutes.stringValue) ?? 0, 0), 59)
        let total = min(max(h * 60 + m, 1), KeepAwake.maxMinutes)
        model.lastMinutes = total
        model.keepAwake(.minutes(total))
    }

    /// Asks for an end time; a time already past today means tomorrow.
    @objc private func chooseTime() {
        if case .until = model.manual { model.stopKeepingAwake(); return }
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Date().addingTimeInterval(3600)
        picker.sizeToFit()
        guard ask(String(localized: "Keep the Mac awake until"), String(localized: "A time within the next 24 hours."), picker, focus: picker) else { return }
        model.keepAwake(.until(KeepAwake.next(picker.dateValue, after: Date())))
    }

    private func ask(_ title: String, _ detail: String, _ accessory: NSView, focus: NSView) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Keep awake"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = focus
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func toggleLid() { model.lidMode.toggle() }
    @objc private func allowClaudeAccess() { model.grantClaudeAccess() }

    // The App Sandbox lets Finder reveal a folder but not open it, so Finder shows it selected in its parent.
    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // Brings the agent's app to the front, the way clicking it in the Dock does. Picking its exact window or tab would need Automation access.
    @objc private func openSession(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Updates

    @objc private func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    // A menu bar app shouldn't pop up a window after a background check, so the menu and a notification offer the update.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        availableUpdate = update.displayVersionString
        if !handleShowingUpdate { model.notifyUpdate(update.displayVersionString) }
        refresh()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableUpdate = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdate = nil
    }

    // Relaunching drops the sleep hold and the lid setting; with the lid closed the Mac would sleep mid-run.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard model.holding else { return false }
        pendingInstall = installHandler
        refresh()
        return true
    }

    // MARK: Settings

    @objc private func openSettings() {
        if settings == nil {
            let options = UpdateOptions(updater: updater.updater)
            updateOptions = options
            settings = SettingsWindow.make(model: model, updates: options)
        }
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
        add([entry(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"),
             entry(String(localized: "Quit Nonstop Agents"), #selector(NSApplication.terminate(_:)), "q")])
        add([entry(String(localized: "Undo"), Selector(("undo:")), "z"),
             entry(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
             entry(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
             entry(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
             entry(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
             entry(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")])
        return bar
    }
}

extension Model {
    /// Off, or on but held back by battery or heat.
    var isPaused: Bool {
        switch status {
        case .off, .battery, .unplugged, .hot: true
        default: false
        }
    }

    /// The switch title, such as "2 Nonstop Agents working".
    var switchTitle: String { String(localized: "\(workingCount) Nonstop Agents working") }

    var stateTitle: String {
        switch status {
        case .off: String(localized: "Nonstop Agents is off")
        case .battery, .unplugged, .hot: String(localized: "Nonstop Agents is paused")
        default: String(localized: "Nonstop Agents is on")
        }
    }

    /// On, mixed when paused or failing, off when turned off.
    var powerState: NSControl.StateValue {
        switch status {
        case .off: .off
        case .battery, .unplugged, .hot, .failed: .mixed
        default: .on
        }
    }

    var summary: String {
        let agents = String(localized: "\(workingCount) agents working")
        switch status {
        case .idle: return String(localized: "No agents working")
        case .working: return lidMode ? String(localized: "\(agents), awake with the lid closed") : String(localized: "\(agents), Mac stays awake")
        case .manual(let until):
            return until == .distantFuture ? String(localized: "Keeping the Mac awake until you stop it")
                : String(localized: "Keeping the Mac awake, \(Self.remaining(until)) left")
        case .off: return workingCount > 0 ? String(localized: "\(agents), Mac may sleep") : String(localized: "Mac sleeps as usual")
        case .battery(let level): return String(localized: "Battery at \(level)%, Mac may sleep")
        case .unplugged: return String(localized: "Unplugged, Mac may sleep")
        case .hot: return String(localized: "Mac is hot and may sleep")
        case .failed: return String(localized: "macOS declined to keep the Mac awake")
        }
    }

    /// Why the Mac may sleep although agents work or a keep-awake runs, under the switch.
    var pauseReason: String? {
        switch status {
        case .battery(let level): String(localized: "Paused at \(level)% battery")
        case .unplugged: String(localized: "Paused while unplugged")
        case .hot: String(localized: "Paused while the Mac is hot")
        case .failed: String(localized: "macOS declined to keep the Mac awake")
        default: nil
        }
    }

    /// Whether closing the lid keeps the Mac awake right now, or why not.
    var lidSubtitle: String? {
        guard lidMode else { return nil }
        if lidUnavailable { return String(localized: "Not available on this Mac") }
        switch lidStop {
        case .time(let minutes): return String(localized: "Stopped after \(Self.duration(minutes)) with the lid closed")
        case .battery(let minutes): return String(localized: "Stopped after \(Self.duration(minutes)) on battery")
        case nil: break
        }
        if !battery.known { return String(localized: "Off, macOS reports no battery state") }
        if lidReady { return String(localized: "Ready to close the lid") }
        return holding ? String(localized: "Getting ready, keep the lid open") : String(localized: "Holds while the Mac is kept awake")
    }

    /// Durations such as "15 minutes" or "1 hour", in the user's language.
    static func duration(_ minutes: Int) -> String {
        durationNames.string(from: TimeInterval(minutes * 60)) ?? ""
    }

    private static let durationNames: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Time left such as "1 hr, 30 min" or "45 sec", in the user's language.
    static func remaining(_ date: Date) -> String {
        remainingFormatter.string(from: max(0, date.timeIntervalSinceNow.rounded())) ?? ""
    }

    private static let remainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
