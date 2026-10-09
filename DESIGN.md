# Nonstop Agents design

## In short

- Nonstop Agents is a pure native macOS app. Every element is a system component, an SF Symbol or a system color.
- The menu bar presence is a pill with the number of working agents and the `sparkle` SF Symbol cut out of it, in SF Mono.
- No custom colors, fonts, views or styling. Appearance, accent color, contrast and accessibility come from macOS.

## Principles

- Use the system component that already does the job before drawing anything.
- Let macOS choose colors: template images in the menu bar, label colors for text, the user's accent color for state.
- Show three things and nothing more: how many agents work, whether the Mac is kept awake, how to stop it.
- Sentence case for every label. Plain words: working, quiet, finished, awake, sleep.
- Every string comes from `Localizable.xcstrings` in English, German, Spanish and French, with Apple's own terms per language. German and Spanish address the user with du and tú, French with vous, as macOS does.

## Menu bar

The status item is a pill with the number of working agents, the `sparkle` SF Symbol and the time left on a timed keep-awake cut out of it, such as `2 ✦ 29m`. It is a template image, so the menu bar tints it for light and dark, like the battery icon with its cutout bolt. Text is SF Mono at 12 pt semibold, so the width holds as numbers change. Every part starts on a whole point, so edges stay sharp on 1x displays.

The pill fills the item. macOS pads a menu bar item by 8 pt on each side and, while the menu is open, draws a 24 pt highlight 2 pt past that. The image's alignment rect leaves that padding out, so the 20 pt pill sits 2 pt inside the highlight on every side. On an external display macOS 27 places items 1 pt above the menu bar's center, where it centers the highlight, so the pill moves down by the measured difference inside a taller image. On the built-in display items sit on the center. The app measures the offset from its status window, which spans the menu bar of the display it is on.

| State | Shows |
| --- | --- |
| On, nothing to do | `✦` |
| Agents working | `2 ✦` |
| Timed keep-awake running | `2 ✦ 29m`, or `✦ 29m` without agents |
| Off, or paused for battery or heat | The same, dimmed through the button's disabled appearance |

- Left click turns the app on or off. Right-click or control-click opens the menu, which also opens settings.
- The tooltip and accessibility label read the state and summary, such as "Nonstop Agents is on. 2 agents working, Mac stays awake."

## Menu

A standard NSMenu, top to bottom:

Every title starts at the same edge. Marks sit in the state column, where checkmarks go: a checkmark for options, and a stock AppKit status image for state.

1. The switch: the number of working agents, such as "2 Nonstop Agents working", without a subtitle. Its state column shows a green status image when on and a yellow one when paused, and stays empty when off. Clicking it turns the app on or off. While it is on, the Mac stays awake until the last agent finishes.
2. Agents: a section header and up to 10 agent items, working ones first. Each agent that keeps the Mac awake right now carries the same green status image. More agents go into an "N more" submenu, which macOS scrolls when it gets long; a menu cannot scroll one section on its own. The title is the task: a Claude Code conversation title, else the project folder, else the tool. The subtitle is tool, folder and working or quiet. Each agent has a submenu with "Open folder", which reveals its folder in Finder, "Open session", which brings the app it runs in to the front, and its process and host app. When the app can't read `~/.claude`, "Allow access to Claude Code…" follows the agents while Claude Code runs.
3. "Stay awake": a section header with "Indefinitely", "For a while" and "With lid closed" as checkmark items. "For a while" has a submenu of durations from 15 minutes to 4 hours, and its subtitle shows the time left. The running choice is checked, and choosing it again stops it.
4. App, without a header: "About Nonstop Agents" (the standard About window), "Settings" with Command-comma, "Quit Nonstop Agents" with Command-Q. macOS 27 adds a gear to Settings; the app hides it so the title lines up.

## Settings

A standard settings window: NSTabViewController with toolbar tabs and the preference toolbar style. The window title follows the selected tab, and the window takes each tab's height with the tab view controller's stock behavior. The app asks to activate after the click and orders the window to the front. Whether it also takes keyboard focus is macOS's decision; otherwise one click focuses it.

Settings hold only lasting options. Everything used day to day is in the menu.

| Tab | Symbol | Contents |
| --- | --- | --- |
| General | `gearshape` | Login; notifications switch with a checkbox per notification; sleep exceptions for battery and heat |
| Agents | `sparkles` | A toggle per agent, apps, local models, other processes |

Nonstop Agents stays a menu bar app while settings are open: no Dock icon and no Command-Tab entry. Settings come back through the menu. A hidden main menu carries Command-W, Command-Q and editing keys for the settings window.

- General and Agents are SwiftUI grouped Forms. Every section has a header, which also sets the space between sections.
- Section footers are plain text, so the form styles them as secondary notes. An option's own description is the second line of its label, which the form shows under it.
- Option labels say what they let macOS do, in one pattern: "Let Mac sleep when reaching this battery level", "Let Mac sleep when reaching high temperatures".
- Turning off the heat exception asks for confirmation in a standard alert first.
- When macOS has notifications for Nonstop Agents turned off, the notifications section says so and links to System Settings.
- Controls are system toggles, pickers, buttons and text fields, unstyled, in the user's accent color.

## Welcome window

Shown once, on first launch. Closing it, with "Get started" or the close button, counts as seen.

- The app icon, "Welcome to Nonstop Agents" and one sentence on what the app does.
- Three points, each an SF Symbol in the accent color with a bold title and a secondary line: where it lives, what it reads, when the Mac still sleeps. The second point says plainly what the app reads and that it sends nothing.
- When the app can't read `~/.claude`, a fourth point explains why it needs Claude Code's status files, with "Allow access…". With the sandbox exception in place it stays hidden.
- Two checkboxes, both opt-in: "Open at login", off, and "Send notifications", on, with a note that macOS asks once. Nothing is registered and no permission is requested until "Get started".

## App icon

A four-point sparkle in plum `#371236` on lavender `#C399FF`, drawn for Nonstop Agents. Four curves meet at the tips, 300 pt from the center of the 1024 pt design, and each curve bends toward the center. It echoes the menu bar's `sparkle` without copying it: Apple's terms keep SF Symbols, and glyphs substantially or confusingly similar to them, out of app icons and logos.

- `Design/Icon/AppIcon.svg` is the source: the full-bleed design, with the sparkle as one path.
- `./build.sh icon` renders it into the asset catalog on the macOS icon grid, an 824 pt rounded square inside 1024 pt, at every size. The plate starts on a whole pixel, so its edges stay sharp on 1x displays.
- The About window gets the icon file itself. At runtime macOS offers a single 256 px rendition, which blurs at About's 64 pt.
- macOS 27 adds glass effects to this flat icon on its own. Layered variants for dark, clear and tinted appearances need an Icon Composer file, made in Xcode.
