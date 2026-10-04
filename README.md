# Until

A dot in the macOS menu bar that counts the AI agents working on your Mac and keeps it awake until they finish, lid closed included. Then it lets the Mac sleep.

## In short

- The dot shows how many agents are working right now. Filled means the Mac is kept awake.
- Click the dot to turn Until on or off. Right-click for the menu with every agent process.
- Detection covers agent CLIs, agents inside editors and apps, and local model runtimes.
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
| Lid closed while the charger is plugged in or out | Not guaranteed on Apple Silicon | Yes, with the sleep helper |
| Sleep helper (`pmset`, admin password once) | Not allowed by App Review 2.4.5(v) | Optional |
| Claude Code status files | After the user grants access to `~/.claude` | Automatic |

## How detection works

Until scans the process table every 5 seconds and keeps the agents it recognises by executable, script path and arguments. Each agent then counts as working on the first signal that applies:

1. The agent reports its state. Claude Code writes `busy`, `waiting` or `idle` per process to `~/.claude/sessions`.
2. It is a one-shot run, such as `claude -p` or `codex exec`, which exits when done.
3. The agent or one of its children holds a sleep assertion, such as the `caffeinate` child Claude Code, Qwen Code and Droid start while working.
4. Its process tree uses CPU: above 2 % of a core while it streams or runs tools. Idle agents measured 0.1 to 0.8 %.
5. It runs a tool process started in the last 10 minutes, so a silent `sleep` or network wait counts. Services started with the agent, such as MCP servers, do not.

An agent stays working for a minute after its last signal. After the last agent finishes, Until keeps the Mac awake for the time set in Settings, 2 minutes by default, then releases. Apps with built-in agents count while the app holds its own sleep assertion: Cursor and VS Code do this while their agent runs.

An editor, terminal or agent that is merely open never counts.

## Supported tools

- Command line agents: Claude Code, Codex, Copilot CLI, Cursor Agent, Gemini CLI, Antigravity CLI, OpenCode, Devin, Amp, Droid, Qwen Code, Grok Build, Kiro CLI, Junie, Warp Agent, Goose, Crush, Cline, Kilo Code, Auggie, Continue, Aider, OpenHands, Mistral Vibe, Plandex.
- The same agents inside editors and apps: VS Code, Cursor, Zed, JetBrains, Xcode, Warp, Conductor, the Claude and ChatGPT apps.
- Apps with built-in agents: Cursor, VS Code, and Claude and ChatGPT when their keep-awake setting is on.
- Local models: Ollama, llama.cpp, LM Studio, MLX.
- Any other tool by process name, added in Settings.

## Safety

- Lid-closed mode disables lid sleep only while Until keeps the Mac awake. A guard process restores it when Until quits or crashes.
- On battery Until stops at the level you set, 20 % by default, also with the lid closed.
- Until lets the Mac sleep when it runs hot, earlier with the lid closed.

## Layout

| Path | Contents |
| --- | --- |
| `Until/` | App sources and the app icon |
| `Config/` | `Info.plist` and the two entitlement files |
| `Checks/` | Detection self-check and live monitor |
| `DESIGN.md` | Design language for the dot, menu and settings |
