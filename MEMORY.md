# Until – Memory

Updated 2026-10-05.

## State

Until is a macOS menu bar app that counts working AI agents and keeps the Mac awake while they work, lid closed included. Repo: private `marco-vrinssen/Until`. Goal: Mac App Store, website later. Not yet tested by Marco with the lid closed, and never built in Xcode.

## Decisions

- Pure native macOS components only, no custom styling. Marco dropped the Linear-based design on 2026-10-04. `DESIGN.md` describes what is used.
- Menu bar: one attributed title, count then `sparkle` (text attachment) then time left on a timed keep-awake, SF Mono. A size configuration on SF Symbols in a status item image crops them. A text title ignores `appearsDisabled`, so off and paused use the secondary label color.
- Left click turns Until on or off, right-click opens the menu, Settings opens from the menu (Marco, 2026-10-05). The first menu item shows the state with a stock status dot (green on, yellow paused, gray off) and also toggles.
- Settings hold only lasting options (General: Login, Notifications, Sleep exceptions; Agents). Turning off the heat exception needs a confirmation. About is the standard About window from the menu, given `AppIcon.icns` because the runtime icon is a single 256 px rendition that blurs at 1x. Controls live in the menu. Until is purely a background menu bar app: no Dock icon, also while settings are open (Marco, 2026-10-05). No settings that change macOS sleep behavior beyond holding idle sleep: display sleep and sleep timers stay with macOS.
- No root `pmset` sleep helper: App Review 2.4.5(v) forbids it, and Marco asked to remove it on 2026-10-05.
- Agents are named after their task. Claude Code: `/rename` name, else the AI title from the transcript (`custom-title`, `ai-title` lines). Others: project folder.
- Menu (Marco, 2026-10-05): switch, up to 10 agents plus an "N more" submenu, "Stay awake" submenu with durations, "Stay awake when lid is closed" below it, then About, Settings, Quit.
- App icon: Marco's draft (Figma file Cortex, `CZUqHSefnCRdBARhtro1xS`, node `1193:278`) was too close to the Artificial Analysis logo. Three concepts in the draft's colors and grid are in `Design/Icon` and, editable, in the Cortex file's Inspiration page, section "Until app icon" (`1196:2`), below the draft. Marco simplified the hourglass (frame `1196:3`) and chose it on 2026-10-05; its export is `Design/Icon/AppIcon.svg`, rendered with `./build.sh icon`. Figma MCP: the personal account (`figma-personal`) has access to Cortex, the work account does not. macOS 27 adds glass effects to a flat icon by itself.
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

- macOS reported notifications for the Direct edition as denied on 2026-10-05; the settings show a link to System Settings.
- A menu item with a subtitle has the accessibility name "title, subtitle", which matters when scripting the menu.
- Marco is often at the Mac. Prefer `screencapture -l <window id>` and accessibility actions over synthetic mouse clicks; moving the mouse during a synthetic click makes it miss.
- `./build.sh check` runs the self-check, `./build.sh check --live` prints this Mac's agents every 5 seconds.
- Push with `env -u GITHUB_TOKEN git push` so a read-only token in the shell can't shadow the keyring login.

## Open

- Lid-closed test on battery without an external display, and with the charger plugged in or out.
- Xcode build of both schemes, then App Store Connect: bundle id, Icon Composer icon, review notes on reading the user's own processes.
- macOS 27 shows the icon on a gray plate at 16 and 32 px (Finder list view, Spotlight), 64 px and up get glass. Seen with and without pixel snapping, cause unknown.
- Codex threads have titles in `~/.codex/state_5.sqlite`; not used yet because no threads existed to verify against.
