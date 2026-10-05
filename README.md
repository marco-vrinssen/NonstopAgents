# Until

A sparkle in the macOS menu bar that counts the AI agents working on your Mac and keeps it awake until they finish, lid closed included. Then macOS sleeps on its own schedule again.

## In short

- The menu bar shows the number of working agents, the sparkle, and the time left on a timed keep-awake. Dimmed means Until is off or paused.
- Click the sparkle to turn Until on or off.
- Right-click for the menu: the current state, every agent named after its task, stay awake for a while, lid closed, settings.
- Two editions from one codebase: App Store (sandboxed) and Direct (Developer ID).

## Build

Xcode is not required. The Command Line Tools build and sign a runnable app.

| Command | Result |
| --- | --- |
| `./build.sh` | Direct edition at `build/Until.app` |
| `./build.sh run` | Builds the direct edition and launches it |
| `./build.sh appstore` | Sandboxed App Store edition at `build/AppStore/Until.app` |
| `./build.sh check` | Runs the detection self-check |
| `./build.sh check --live` | Prints this Mac's agents and their state every 5 seconds |
| `./build.sh icon` | Renders `Design/Icon/AppIcon.svg` into the app icon set |

Builds are universal (Apple Silicon and Intel), need macOS 15 or later, and are signed ad hoc. For distribution, open `Until.xcodeproj` in Xcode 26 or later and pick a scheme:

| Scheme | Runs | Archives |
| --- | --- | --- |
| Until | App Store edition | Release, sandboxed, for App Store Connect |
| Until Direct | Direct edition | Direct, hardened runtime, for Developer ID and notarization |

Set your team under Signing and Capabilities before archiving. Version and bundle id live in `Config/Info.plist`.

## Editions

| Feature | App Store | Direct |
| --- | --- | --- |
| Agent detection | Yes | Yes |
| Stay awake with lid closed | Yes, through IOKit, no password | Yes, through IOKit, no password |
| Claude Code status and titles | After the user grants access to `~/.claude` | Automatic |

Plugging the charger in or out with the lid closed can still put some Apple Silicon Macs to sleep. A root `pmset` helper would cover it, but App Review rule 2.4.5(v) forbids root helpers, so Until has none.

## How detection works

Until scans the process table every 5 seconds and keeps the agents it recognises by executable, script path and arguments. Each agent then counts as working on the first signal that applies:

1. The agent reports its state. Claude Code writes `busy`, `waiting` or `idle` per process to `~/.claude/sessions`.
2. It is a one-shot run, such as `claude -p` or `codex exec`, which exits when done.
3. The agent or one of its children holds a sleep assertion, such as the `caffeinate` child Claude Code, Qwen Code and Droid start while working.
4. Its process tree uses CPU: above 2 % of a core while it streams or runs tools. Idle agents measured 0.1 to 0.8 %.
5. It runs a tool process started in the last 10 minutes, so a silent `sleep` or network wait counts. Services started with the agent, such as MCP servers, do not.

An agent that reports its own state is released the moment it says it is done. Any other agent stays working for two minutes after its last signal, which covers a model thinking without output. Until only blocks idle system sleep; display sleep and the sleep timers stay with macOS.

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

- Lid-closed mode disables lid sleep only while Until keeps the Mac awake. A guard process restores it when Until quits or crashes.
- On battery Until stops at the level you set, 20% by default, also with the lid closed.
- Until lets the Mac sleep when it runs hot, earlier with the lid closed.

## Layout

| Path | Contents |
| --- | --- |
| `Until/` | App sources and the app icon |
| `Config/` | `Info.plist` and the two entitlement files |
| `Checks/` | Detection self-check and live monitor |
| `DESIGN.md` | Design language for the dot, menu and settings |
