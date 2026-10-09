# Nonstop Agents

## Rules

- The name is Nonstop Agents, with "Nonstop" as one word. Never write "NonStop", which is how HPE styles its servers, or "Non-Stop".
- Native macOS components and stock behavior only, as `DESIGN.md` describes. No tab or window animations. The only forced behaviors are hiding the gear macOS 27 adds to Settings in the menu and ordering the settings window to the front.
- The status item is a template image, not an attributed title. A title's sparkle attachment blurs at 1x, and titles ignore `appearsDisabled`, which dims off and paused.
- No settings that change macOS sleep beyond holding idle sleep.
- The app icon is the app's own sparkle. Never put an SF Symbol or a look-alike in the app icon or a logo; Apple's terms forbid it.
- In the App Sandbox, `NSWorkspace.open` and `selectFile(_:inFileViewerRootedAtPath:)` can't show a folder outside the container, but `activateFileViewerSelecting` and `openApplication(at:)` work. Tested on 2026-10-08.
- Every user-facing string goes through `String(localized:)` or a SwiftUI literal and has German, Spanish and French in `NonstopAgents/Localizable.xcstrings`. `xcodebuild -exportLocalizations` lists every key the code uses.
- There is one edition, the sandboxed App Store app. Build it with Xcode or `./build.sh`.

## Checks

- Prefer `screencapture -l <window id>` and accessibility actions over synthetic mouse clicks. The user is often at the Mac, and moving the mouse during a synthetic click makes it miss.
- `screencapture -l` can't capture the status item window. Capture it by region.
- The status button's height follows the image, and its frame moves with the image's alignment rect. Measure the item's position from `alignmentRect(forFrame:)`.
- macOS clips a status image to its alignment rect. An alignment rect that reaches past the image crops it, so move content inside a taller image instead.
- Restarting the app drops its sleep hold. With the display off and nobody at the Mac, the Mac sleeps at once. Run `caffeinate -i -t 30 &` before `pkill -x "Nonstop Agents"`.
- A menu item with a subtitle has the accessibility name "title, subtitle". Script the menu with that name.
- Once the app has saved a setting, `defaults write com.marcovrinssen.nonstopagents` writes into its sandbox container. Before that it writes to `~/Library/Preferences`, which the sandboxed app never reads, so write to `~/Library/Containers/com.marcovrinssen.nonstopagents/Data/Library/Preferences/com.marcovrinssen.nonstopagents` instead.
- Show the welcome window again with `defaults write <container path from above> onboarded -bool false`, and pick a language with `open "build/Nonstop Agents.app" --args -AppleLanguages "(de)"`.

## Release

Releases are free GitHub releases of an ad hoc signed build, because there is no paid Apple developer account. Never sign with the Frans Health GmbH team.

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Config/Info.plist`.
2. Run `./build.sh release`.
3. Run `gh release create v<version> build/NonstopAgents-<version>.zip build/NonstopAgents.zip --title "Nonstop Agents <version>"` with short notes. The unversioned zip keeps the README's Terminal install working.
