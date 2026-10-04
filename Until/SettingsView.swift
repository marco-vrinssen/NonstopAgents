import AppKit
import SwiftUI

extension NSColor {
    /// The one accent from DESIGN.md: lavender for working state and controls.
    static let untilAccent = NSColor(name: "untilAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x82 / 255, green: 0x8F / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255, alpha: 1)
    }
}

extension Color {
    static let untilAccent = Color(nsColor: .untilAccent)
}

/// Text typed into the settings window. A class rather than @State, whose macro
/// plugin ships only with Xcode and not with the Command Line Tools.
@MainActor
@Observable
final class SettingsDraft {
    var newName = ""
    var helperMessage: String?
}

struct SettingsView: View {
    @Bindable var model: Model
    let draft = SettingsDraft()

    var body: some View {
        TabView {
            GeneralPane(model: model, draft: draft).tabItem { Text("General") }
            AgentsPane(model: model, draft: draft).tabItem { Text("Agents") }
        }
        .tint(.untilAccent)
        .frame(width: 480, height: 600)
    }
}

extension SettingsView {
    /// Renders both panes in light and dark into PNGs from an off-screen window, for design review.
    static func snapshot(model: Model, to directory: String) {
        let draft = SettingsDraft()
        let panes: [(String, AnyView)] = [
            ("general", AnyView(GeneralPane(model: model, draft: draft))),
            ("agents", AnyView(AgentsPane(model: model, draft: draft))),
        ]
        for (name, pane) in panes {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let size = NSRect(x: 0, y: 0, width: 480, height: 600)
                let host = NSHostingView(rootView: pane.tint(.untilAccent).frame(width: 480, height: 600))
                let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(directory)/settings-\(name)-\(look).png"))
                }
                window.orderOut(nil)
            }
        }
    }
}

private struct GeneralPane: View {
    @Bindable var model: Model
    @Bindable var draft: SettingsDraft

    var body: some View {
        Form {
            Section {
                Toggle("Keep the Mac awake while agents work", isOn: $model.enabled)
                Toggle("Open at login", isOn: Binding(get: { model.loginItem }, set: model.setLoginItem))
                Picker("Left click", selection: $model.leftClickShowsMenu) {
                    Text("Turns Until on or off").tag(false)
                    Text("Opens the menu").tag(true)
                }
            }

            Section {
                Picker("After agents finish", selection: $model.holdMinutes) {
                    Text("Sleep right away").tag(0)
                    ForEach([1, 2, 5, 10], id: \.self) { Text("Stay awake \($0) min").tag($0) }
                }
                Toggle("Keep the display on", isOn: $model.keepDisplayOn)
            } footer: {
                Note("An agent counts as finished after a minute without activity. The extra time covers long pauses while a model thinks.")
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
                Note("Until disables lid sleep only while it keeps the Mac awake and hands it back when agents finish. Plugging the charger in or out with the lid closed can still put some Macs to sleep.")
                #else
                Note("Until disables lid sleep only while it keeps the Mac awake and hands it back when agents finish. The sleep helper also covers plugging the charger in or out with the lid closed.")
                #endif
            }

            Section {
                LabeledContent("On battery, stop at") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.batteryFloor) }, set: { model.batteryFloor = Int($0) }),
                               in: 5...50, step: 5)
                        Text("\(model.batteryFloor)%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } header: {
                Text("Battery")
            } footer: {
                Note(model.battery.level.map { "Now at \($0)%. Below the limit Until lets the Mac sleep, also with the lid closed." }
                     ?? "This Mac has no battery.")
            }

            Section {
                Toggle("Let the Mac sleep when it gets hot", isOn: $model.thermalGuard)
                Toggle("Notify me when agents finish", isOn: $model.notify)
            } header: {
                Text("Safety")
            } footer: {
                Note("Until \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            }
        }
        .formStyle(.grouped)
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
                Note("An agent counts while it streams a reply, runs tools or reports itself busy. One that waits for you, or an editor or terminal that is merely open, does not.")
            }

            #if APPSTORE
            Section {
                LabeledContent("Claude Code status") {
                    if model.claudeAccess {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow access…") { model.grantClaudeAccess() }
                    }
                }
            } footer: {
                Note("Claude Code reports whether each session is busy or waiting for you in the .claude folder. Reading it keeps the count exact while a model thinks for minutes.")
            }
            #endif

            Section {
                ForEach(Agent.all.filter { $0.binaries.isEmpty && !$0.apps.isEmpty }) { toggle($0) }
            } header: {
                Text("Apps")
            } footer: {
                Note("Counted while the app keeps your Mac awake for its own agent. Claude and ChatGPT do so when their keep-awake setting is on.")
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
                Note("Add any command line tool by its process name. It counts while it works, like the agents above.")
            }
        }
        .formStyle(.grouped)
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

/// Secondary text under a settings section.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
