import AppKit
import SwiftUI

/// The first-launch window: what the app does, what it reads, and two opt-in choices.
/// macOS asks for notification permission only after the user turns notifications on here or in Settings.
@MainActor
enum WelcomeWindow {
    static func make(model: Model) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: WelcomeView(model: model) { [weak window] in window?.close() })
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
        window.title = String(localized: "Welcome to Nonstop Agents")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private struct WelcomeView: View {
    let model: Model
    let done: () -> Void
    @State private var openAtLogin = false
    @State private var notify = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Welcome to Nonstop Agents")
                    .font(.title2.bold())
                Text("Your Mac stays awake while AI agents work, so they run nonstop. When the last one finishes, your Mac sleeps as usual.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16) {
                point("sparkle", "Lives in the menu bar",
                      "The sparkle shows how many agents are working. Click it to turn Nonstop Agents on or off, right-click for the menu.")
                point("lock", "Stays on your Mac",
                      "Nonstop Agents sees which agents are running and, for Claude Code, each session's status and title. It reads nothing else and sends nothing anywhere.")
                point("battery.50percent", "Lets your Mac rest",
                      "Your Mac still sleeps on low battery or when it runs hot. It stays awake with the lid closed only if you choose that in the menu.")

                // Only when the App Store build runs without its ~/.claude exception.
                if !model.claudeAccess {
                    point("folder", "One click for Claude Code",
                          "To tell working Claude Code sessions from idle ones, Nonstop Agents reads their status files. macOS asks you to choose the folder once, and access stays read-only.")
                    Button("Allow access…") { model.grantClaudeAccess() }
                        .padding(.leading, 40)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Open at login", isOn: $openAtLogin)
                Toggle("Send notifications", isOn: $notify)

                // A checkbox shows a second label line on one line only, so the note sits under it and wraps.
                Text("When agents finish while you're away, or your Mac pauses for battery or heat. macOS asks you once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.top, -6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Get started", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(width: 460)
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        if openAtLogin { model.setLoginItem(true) }

        // Setting it asks macOS for permission when on, and keeps notifications off otherwise.
        model.notificationsEnabled = notify
        done()
    }
}
