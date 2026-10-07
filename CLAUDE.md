# Until

## Rules

- Native macOS components and stock behavior only, as `DESIGN.md` describes. No tab or window animations. The only forced behaviors are the status dot's image visibility and ordering the settings window to the front.
- The status item is a template image, not an attributed title. A title's sparkle attachment blurs at 1x, and titles ignore `appearsDisabled`, which dims off and paused.
- No settings that change macOS sleep beyond holding idle sleep. The one exception is the menu's one-time "When agents finish" choice, which sleeps or shuts down the Mac once.
- Don't use SwiftUI `@State`. In the macOS 27 SDK its macro plugin ships only with Xcode, so the Command Line Tools can't build it. Use `@Observable` classes.

## Checks

- Prefer `screencapture -l <window id>` and accessibility actions over synthetic mouse clicks. The user is often at the Mac, and moving the mouse during a synthetic click makes it miss.
- `screencapture -l` can't capture the status item window. Capture it by region.
- The status button's height follows the image, and its frame moves with the image's alignment rect. Measure the item's position from `alignmentRect(forFrame:)`.
- macOS clips a status image to its alignment rect. An alignment rect that reaches past the image crops it, so move content inside a taller image instead.
- Restarting Until drops its sleep hold. With the display off and nobody at the Mac, the Mac sleeps at once. Run `caffeinate -i -t 30 &` before `pkill -x Until`.
- Never test Sleep right away or Shut down for real while agents work. `./build.sh check` covers the countdown.
- A menu item with a subtitle has the accessibility name "title, subtitle". Script the menu with that name.
- Once the App Store edition has run, `defaults write com.marcovrinssen.until` writes into its sandbox container.
