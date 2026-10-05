# Until – Memory

Updated 2026-10-05.

## State

Until is a macOS menu bar app that counts working AI agents and keeps the Mac awake while they work, lid closed included. Repo: private `marco-vrinssen/Until`. Goal: Mac App Store, website later. Not yet tested by Marco with the lid closed, and never built in Xcode.

## Decisions

- Pure native macOS components only, no custom styling. Marco dropped the Linear-based design on 2026-10-04. `DESIGN.md` describes what is used.
- Menu bar: `sparkle` SF Symbol plus the working count in SF Mono. A size configuration on SF Symbols makes the status bar crop them, so there is none.
- Left click opens settings, right-click opens the menu. The on or off switch is the first menu item with a stock status dot (green on, yellow paused, gray off).
- Settings hold only lasting options (General, Agents, About). Controls live in the menu. No settings that change macOS sleep behavior beyond holding idle sleep: display sleep and sleep timers stay with macOS.
- No root `pmset` sleep helper: App Review 2.4.5(v) forbids it, and Marco asked to remove it on 2026-10-05.
- Agents are named after their task. Claude Code: `/rename` name, else the AI title from the transcript (`custom-title`, `ai-title` lines). Others: project folder.
- Stock behavior over custom: no tab or window animations. The only forced bits are the status dot's image visibility and ordering the settings window to the front.

## Build

- The dev Mac has no Xcode, only Command Line Tools. `./build.sh` builds with swiftc. The hand-written `Until.xcodeproj` was never opened in Xcode.
- With the macOS 27 SDK, SwiftUI `@State` is a macro whose plugin ships only with Xcode, so the code uses `@Observable` classes instead.

## Editions

| Edition | Bundle id | Notes |
|---|---|---|
| App Store | `com.marcovrinssen.until` | Sandboxed. Reads `~/.claude` only after the user grants the folder. Once it has run, `defaults write com.marcovrinssen.until` writes into its container |
| Direct | `com.marcovrinssen.until.direct` | Not sandboxed, reads `~/.claude` directly |

Lid closed uses `kPMSetClamshellSleepState` (Amphetamine's method) in a `--lid-guard` child process that restores lid sleep when Until quits or crashes.

## Testing

- Marco is often at the Mac. Prefer `screencapture -l <window id>` and accessibility actions over synthetic mouse clicks; moving the mouse during a synthetic click makes it miss.
- `./build.sh check` runs the self-check, `./build.sh check --live` prints this Mac's agents every 5 seconds.
- Push with `env -u GITHUB_TOKEN git push` so a read-only token in the shell can't shadow the keyring login.

## Open

- Lid-closed test on battery without an external display, and with the charger plugged in or out.
- Xcode build of both schemes, then App Store Connect: bundle id, Icon Composer icon, review notes on reading the user's own processes.
- Codex threads have titles in `~/.codex/state_5.sqlite`; not used yet because no threads existed to verify against.
