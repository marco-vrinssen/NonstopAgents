import AppKit
import SwiftUI

/// Text typed into the settings window. A class rather than @State, whose macro
/// plugin ships only with Xcode and not with the Command Line Tools.
@MainActor
@Observable
final class SettingsDraft {
    var newName = ""
}

/// The settings window: toolbar tabs, the native macOS settings layout, one grouped form per tab.
/// Only lasting options live here; the controls are in the menu bar menu.
@MainActor
enum SettingsWindow {
    static let aboutTab = 2

    static func make(model: Model) -> NSWindow {
        let panes: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralPane(model: model))),
            ("Agents", "sparkles", AnyView(AgentsPane(model: model, draft: SettingsDraft()))),
            ("About", "info.circle", AnyView(AboutPane())),
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

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { model.loginItem }, set: model.setLoginItem))
            }

            Section {
                Toggle("Send notifications", isOn: $model.notify)
            } header: {
                Text("Notifications")
            } footer: {
                Text("When agents finish while you are away from the Mac, and when Until pauses for battery.")
            }

            Section {
                Picker("On battery, stop at", selection: $model.batteryFloor) {
                    ForEach(Array(stride(from: 5, through: 50, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                    Text("Never stay awake on battery").tag(100)
                }
                Toggle("Let the Mac sleep when it gets hot", isOn: $model.thermalGuard)
            } header: {
                Text("Power")
            } footer: {
                Text(model.battery.level.map { "Now at \($0)%. At or below the limit Until lets the Mac sleep, also with the lid closed." }
                     ?? "This Mac has no battery.")
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
                Text("Claude Code keeps each session's state and title in the .claude folder. Reading it keeps the count exact and names each session after its conversation.")
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

private struct AboutPane: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Until")
                .font(.title2)
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))")
                .foregroundStyle(.secondary)
            Text("Keeps your Mac awake while AI agents work, and lets it sleep when they are done.")
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Text(info["NSHumanReadableCopyright"] as? String ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
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
