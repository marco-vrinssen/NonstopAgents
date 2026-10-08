import AppKit
import SwiftUI

/// Text typed into the settings window. A class rather than @State, whose macro
/// plugin ships only with Xcode and not with the Command Line Tools.
@MainActor
@Observable
final class SettingsDraft {
    var newName = ""
    var confirmHeatOff = false
}

/// The settings window: toolbar tabs, the native macOS settings layout, one grouped form per tab.
/// Only lasting options live here; the controls are in the menu bar menu.
@MainActor
enum SettingsWindow {
    static func make(model: Model) -> NSWindow {
        let draft = SettingsDraft()
        let panes: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralPane(model: model, draft: draft))),
            ("Agents", "sparkles", AnyView(AgentsPane(model: model, draft: draft))),
        ]
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (label, symbol, pane) in panes {
            let host = NSHostingController(rootView: pane)
            host.sizingOptions = .preferredContentSize
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
        window.center()
        return window
    }
}

private struct GeneralPane: View {
    @Bindable var model: Model
    @Bindable var draft: SettingsDraft

    var body: some View {
        Form {
            Section("Login") {
                Toggle("Open at login", isOn: Binding(get: { model.loginItem }, set: model.setLoginItem))
            }

            Section {
                Toggle("Send notifications", isOn: $model.notificationsEnabled)
                Group {
                    Toggle("When agents finish while you are away", isOn: $model.notifyFinished)
                    Toggle("When reaching the battery level", isOn: $model.notifyBattery)
                    Toggle("When reaching high temperatures", isOn: $model.notifyHeat)
                }
                .toggleStyle(.checkbox)
                .disabled(!model.notificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                if model.notificationsDenied {
                    HStack {
                        Text("Notifications for Nonstop Agents are turned off in System Settings.")
                        Spacer()
                        Button("Open System Settings") {
                            let id = Bundle.main.bundleIdentifier ?? ""
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
                        }
                    }
                }
            }

            Section("Sleep exceptions") {
                Picker(selection: $model.batteryFloor) {
                    ForEach(Array(stride(from: 5, through: 50, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                } label: {
                    Text("Let Mac sleep when reaching this battery level")
                    Text(model.battery.level.map { "Applies on battery, also with the lid closed. Now at \($0)%." }
                         ?? "Applies on battery. This Mac has none.")
                }
                Toggle(isOn: Binding(get: { model.thermalGuard }, set: { on in
                    // Turning it off can let a closed Mac overheat, so that needs a confirmation.
                    if on { model.thermalGuard = true } else { draft.confirmHeatOff = true }
                })) {
                    Text("Let Mac sleep when reaching high temperatures")
                    Text("Applies when macOS reports high temperatures, sooner with the lid closed.")
                }
            }
        }
        .pane()
        .onAppear(perform: model.refreshNotificationStatus)
        .alert("Keep Mac awake at high temperatures?", isPresented: $draft.confirmHeatOff) {
            Button("Keep awake", role: .destructive) { model.thermalGuard = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nonstop Agents will no longer let the Mac sleep when it runs hot. Closed in a bag, it can overheat.")
        }
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
                Text("An agent counts while it works, not while it waits for you.")
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
                Text("Lets Nonstop Agents read each Claude Code session's state and title.")
            }
            #endif

            Section {
                ForEach(Agent.all.filter { $0.binaries.isEmpty && !$0.apps.isEmpty }) { toggle($0) }
            } header: {
                Text("Apps")
            } footer: {
                Text("Cursor and VS Code count while their built-in agent runs, Claude during remote turns.")
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
                Text("Add any command line tool by its process name. It counts while it works.")
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
