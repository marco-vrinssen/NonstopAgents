# Until – Memory

Updated 2026-10-04. Moved here from Marco's machine-local Claude memory so everyone working on the repo has it.

## State

Until is a macOS menu bar dot that counts working AI agents and keeps the Mac awake, lid closed included. First version built 2026-10-04. Repo: private `marco-vrinssen/Until`. Goal: Mac App Store, website later.

## Build

- The dev Mac has no Xcode, only Command Line Tools. `./build.sh` builds with swiftc. The hand-written `Until.xcodeproj` was never opened in Xcode.
- With the macOS 27 SDK, SwiftUI `@State` is a macro whose plugin ships only with Xcode, so the code uses `@Observable` classes instead.

## Editions

| Edition | Bundle id | Notes |
|---|---|---|
| App Store | `com.marcovrinssen.until` | Sandboxed. Once it has run, `defaults write com.marcovrinssen.until` writes into its container, not the global domain |
| Direct | `com.marcovrinssen.until.direct` | Only edition with the root `pmset disablesleep` helper (App Review 2.4.5(v)) |

Lid closed uses `kPMSetClamshellSleepState` (Amphetamine's method) in a `--lid-guard` child process.

## Testing

- Marco is often at the Mac while sessions run. Render UI off-screen with `--snapshot <dir>` instead of popping menus or windows.
- Push with `env -u GITHUB_TOKEN git push` so a read-only token in the shell can't shadow the keyring login.
