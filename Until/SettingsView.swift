import AppKit
import SwiftUI

/// Text typed into the settings window. A class rather than @State, whose macro
/// plugin ships only with Xcode and not with the Command Line Tools.
@MainActor
@Observable
final class SettingsDraft {
    var newName = ""
    var helperMessage: String?
}

/// Toolbar tabs that crossfade and animate the window to each tab's height, like the
/// settings windows of Apple's own apps.
final class SettingsTabs: NSTabViewController {
    /// The size SwiftUI wants for a tab: its fixed width and its content's height.
    static func size(of item: NSTabViewItem?) -> CGSize? {
        (item?.viewController as? NSHostingController<AnyView>)?.sizeThatFits(in: CGSize(width: 500, height: 10_000))
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let window = view.window, let content = window.contentView, let size = Self.size(of: item) else { return }
        // Grow or shrink from the bottom so the toolbar stays where it is.
        var frame = window.frame
        frame.size.height += size.height - content.frame.height
        frame.origin.y = window.frame.maxY - frame.height
        // The animator resizes without blocking, so it runs together with the crossfade.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        }
    }
}

/// The settings window: toolbar tabs, the native macOS settings layout, one grouped form per tab.
/// The window takes each tab's height, so short tabs do not scroll.
@MainActor
enum SettingsWindow {
    static func make(model: Model) -> NSWindow {
        let draft = SettingsDraft()
        let panes: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralPane(model: model))),
            ("Power", "bolt", AnyView(PowerPane(model: model, draft: draft))),
            ("Agents", "sparkles", AnyView(AgentsPane(model: model, draft: draft))),
        ]
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for (label, symbol, pane) in panes {
            let host = NSHostingController(rootView: pane)
            // SettingsTabs sizes the window itself, so the panes set no size constraints.
            host.sizingOptions = []
            // The tab view controller shows the selected tab's title as the window title.
            host.title = label
            let item = NSTabViewItem(viewController: host)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        if let first = SettingsTabs.size(of: tabs.tabViewItems.first) { window.setContentSize(first) }
        window.center()
        return window
    }
}

private struct GeneralPane: View {
    @Bindable var model: Model

    var body: some View {
        Form {
            Section("Until") {
                Toggle("Keep the Mac awake while agents work", isOn: $model.enabled)
                Toggle("Open at login", isOn: Binding(get: { model.loginItem }, set: model.setLoginItem))
                Picker("Left click", selection: $model.leftClickShowsMenu) {
                    Text("Turns Until on or off").tag(false)
                    Text("Opens the menu").tag(true)
                }
            }

            Section {
                Toggle("Send notifications", isOn: $model.notify)
            } header: {
                Text("Notifications")
            } footer: {
                Text("When agents finish while you are away from the Mac, and when Until pauses for battery.")
            }
        }
        .pane()
    }
}

private struct PowerPane: View {
    @Bindable var model: Model
    @Bindable var draft: SettingsDraft

    var body: some View {
        Form {
            Section {
                Picker("After agents finish", selection: $model.holdMinutes) {
                    Text("Sleep right away").tag(0)
                    ForEach([1, 2, 5, 10], id: \.self) { Text("Stay awake \($0) min").tag($0) }
                }
                Toggle("Keep the display on", isOn: $model.keepDisplayOn)
            } header: {
                Text("Staying awake")
            } footer: {
                Text("An agent counts as finished after a minute without activity. The extra time covers long pauses while a model thinks.")
            }

            Section {
                Toggle("Stay awake with the lid closed", isOn: $model.lidMode)
                #if !APPSTORE
                Toggle("Also when the charger is plugged in or out", isOn: $model.chargerProof)
                    .disabled(!SleepGuard.isInstalled || !model.lidMode)
                LabeledContent {
                    Button(SleepGuard.isInstalled ? "Remove" : "Install…") {
                        draft.helperMessage = SleepGuard.isInstalled ? model.uninstallSleepGuard() : model.installSleepGuard()
                    }
                } label: {
                    Text("Sleep helper")
                    Text(draft.helperMessage ?? (model.sleepGuardFailed ? "Could not start, reinstall it"
                        : SleepGuard.isInstalled ? "Installed" : "Asks for your admin password once"))
                }
                #endif
            } header: {
                Text("Lid closed")
            } footer: {
                #if APPSTORE
                Text("Until disables lid sleep only while it keeps the Mac awake and hands it back when agents finish. Plugging the charger in or out with the lid closed can still put some Macs to sleep.")
                #else
                Text("Until disables lid sleep only while it keeps the Mac awake and hands it back when agents finish. The sleep helper also covers plugging the charger in or out with the lid closed.")
                #endif
            }

            Section {
                LabeledContent("On battery, stop at") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.batteryFloor) }, set: { model.batteryFloor = Int($0) }),
                               in: 5...100, step: 5)
                        Text("\(model.batteryFloor)%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } header: {
                Text("Battery")
            } footer: {
                Text(model.battery.level.map { "Now at \($0)%. At or below the limit Until lets the Mac sleep, also with the lid closed. At 100% it never keeps the Mac awake on battery." }
                     ?? "This Mac has no battery.")
            }

            Section("Heat") {
                Toggle("Let the Mac sleep when it gets hot", isOn: $model.thermalGuard)
            }
        }
        .pane()
    }
}

private struct AgentsPane: View {
    @Bindable var model: Model
    @Bindable var draft: SettingsDraft

    var body: some View {
        Form {
            Section {
                ForEach(Agent.all.filter { !$0.isModel && !$0.binaries.isEmpty }) { toggle($0) }
            } header: {
                Text("Agents")
            } footer: {
                Text("An agent counts while it streams a reply, runs tools or reports itself busy. One that waits for you, or an editor or terminal that is merely open, does not.")
            }

            #if APPSTORE
            Section {
                LabeledContent("Status files") {
                    if model.claudeAccess {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow access…") { model.grantClaudeAccess() }
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Claude Code reports whether each session is busy or waiting for you in the .claude folder. Reading it keeps the count exact while a model thinks for minutes.")
            }
            #endif

            Section {
                ForEach(Agent.all.filter { $0.binaries.isEmpty && !$0.apps.isEmpty }) { toggle($0) }
            } header: {
                Text("Apps")
            } footer: {
                Text("Cursor and VS Code count while their built-in agent runs. Claude counts while it runs a turn sent to it remotely. Their agents on the command line are listed above.")
            }

            Section("Local models") {
                ForEach(Agent.all.filter(\.isModel)) { toggle($0) }
            }

            Section {
                ForEach(model.customAgents, id: \.self) { name in
                    LabeledContent(name) {
                        Button("Remove") { model.customAgents.removeAll { $0 == name } }
                    }
                }
                HStack {
                    TextField("Process name", text: $draft.newName, prompt: Text("my-agent"))
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Other processes")
            } footer: {
                Text("Add any command line tool by its process name. It counts while it works, like the agents above.")
            }
        }
        .pane(height: 560)
    }

    private func toggle(_ agent: Agent) -> some View {
        Toggle(agent.name, isOn: Binding(
            get: { !model.disabledAgents.contains(agent.id) },
            set: { on in
                if on { model.disabledAgents.remove(agent.id) } else { model.disabledAgents.insert(agent.id) }
            }))
    }

    private func add() {
        let name = draft.newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !model.customAgents.contains(name) else { return }
        model.customAgents.append(name)
        draft.newName = ""
    }
}

extension View {
    /// One settings tab: a grouped form at a fixed width. Without a height it takes its content's
    /// height, so the window fits the tab; long tabs pass a height and scroll.
    func pane(height: CGFloat? = nil) -> some View {
        formStyle(.grouped)
            .frame(width: 500, height: height)
            .fixedSize(horizontal: false, vertical: height == nil)
    }
}
