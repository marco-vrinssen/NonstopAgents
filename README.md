# Nonstop Agents

Keeps your Mac awake while AI agents work, lid closed included, so they run nonstop. A sparkle in the menu bar counts the working agents. When they finish, macOS sleeps on its own schedule again.

## In short

- The menu bar shows a pill with the number of working agents, the sparkle, and the time left on a timed keep-awake cut out of it. Dimmed means the app is off or paused.
- Click the sparkle to turn the app on or off.
- Right-click for the menu: the number of working agents, every agent named after its task with a green dot while it works and its folder and session one click away, stay awake indefinitely or for a while, with the lid closed, settings.
- A welcome window on first launch says what the app does and what it reads, and offers opening at login and notifications. Both are off until you choose them, and macOS asks for notifications only then.
- In English, German, Spanish and French.

## Build

Open `NonstopAgents.xcodeproj` in Xcode 26 or later and run the "Nonstop Agents" scheme, or use the script, which calls `xcodebuild`:

| Command | Result |
| --- | --- |
| `./build.sh` | The app at `build/Nonstop Agents.app`, signed ad hoc with its sandbox entitlements |
| `./build.sh run` | Builds and launches it |
| `./build.sh check` | Runs the detection self-check |
| `./build.sh check --live` | Prints this Mac's agents and their state every 5 seconds |
| `./build.sh icon` | Renders `Design/Icon/AppIcon.svg` into the app icon set |

Builds are universal (Apple Silicon and Intel) and need macOS 15 or later. For App Store Connect, set your team under Signing and Capabilities and archive the scheme in Xcode. The version lives in `Config/Info.plist`, the bundle ID `com.marcovrinssen.nonstopagents` in the Xcode project.

## Sandbox

The app is sandboxed, as the Mac App Store requires.

| Feature | How |
| --- | --- |
| Agent detection | The process table, readable inside the sandbox for the user's own processes |
| Stay awake with lid closed | IOKit, no password |
| Claude Code status and titles | A read-only sandbox exception for `~/.claude`. If App Review declines it, the user allows access once, from the welcome window or the menu |
| Open folder | Finder reveals the folder; the sandbox doesn't let the app open it |
| Open session | Brings the agent's app to the front, without picking a window or tab |

Plugging the charger in or out with the lid closed can still put some Apple Silicon Macs to sleep. A root `pmset` helper would cover it, but App Review rule 2.4.5(v) forbids root helpers, so Nonstop Agents has none.

## How detection works

Nonstop Agents scans the process table every 5 seconds and keeps the agents it recognises by executable, script path and arguments. Each agent then counts as working on the first signal that applies:

1. The agent reports its state. Claude Code writes `busy`, `waiting` or `idle` per process to `~/.claude/sessions`.
2. It is a one-shot run, such as `claude -p` or `codex exec`, which exits when done.
3. The agent or one of its children holds a sleep assertion, such as the `caffeinate` child Claude Code, Qwen Code and Droid start while working.
4. Its process tree uses CPU: above 2 % of a core while it streams or runs tools. Idle agents measured 0.1 to 0.8 %.
5. It runs a tool process started in the last 10 minutes, so a silent `sleep` or network wait counts. Services started with the agent, such as MCP servers, do not.

An agent that reports its own state is released the moment it says it is done. Any other agent stays working for two minutes after its last signal, which covers a model thinking without output. Nonstop Agents only blocks idle system sleep; display sleep and the sleep timers stay with macOS.

Each agent is named after its task. Claude Code sessions use the name set with `/rename`, else the title Claude Code writes for the conversation. Other agents use their project folder.

Apps with built-in agents count while the app holds a sleep assertion for its agent: Cursor and VS Code while their agent runs, Claude while it runs a remote turn. Assertions that only mean "keep awake" are ignored, such as Claude's own keep-awake setting.

An editor, terminal or agent that is merely open never counts.

## Supported tools

- Command line agents: Claude Code, Codex, Copilot CLI, Cursor Agent, Gemini CLI, Antigravity CLI, OpenCode, Devin, Amp, Droid, Qwen Code, Grok Build, Kiro CLI, Junie, Warp Agent, Goose, Crush, Cline, Kilo Code, Auggie, Continue, Aider, OpenHands, Mistral Vibe, Plandex.
- The same agents inside editors and apps: VS Code, Cursor, Zed, JetBrains, Xcode, Warp, Conductor, the Claude Code tab and the ChatGPT app's local tasks.
- Apps with built-in agents: Cursor, VS Code, and Claude for remote turns.
- Local models: Ollama, llama.cpp, LM Studio, MLX.
- Any other tool by process name, added in Settings.

## Safety

- Lid-closed mode disables lid sleep only while the app keeps the Mac awake. A guard process restores it when the app quits or crashes.
- On battery, Nonstop Agents stops at the level you set, 20% by default, also with the lid closed.
- Nonstop Agents lets the Mac sleep when it runs hot, earlier with the lid closed.

## Layout

| Path | Contents |
| --- | --- |
| `NonstopAgents/` | App sources, the app icon and `Localizable.xcstrings` with every string in four languages |
| `Config/` | `Info.plist` and the entitlements |
| `Checks/` | Detection self-check and live monitor |
| `DESIGN.md` | Design language for the menu bar, menu, settings and welcome window |
