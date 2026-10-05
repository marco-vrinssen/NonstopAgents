# Until design

## In short

- Until is a pure native macOS app. Every element is a system component, an SF Symbol or a system color.
- The menu bar presence is the `sparkle` SF Symbol with the number of working agents next to it in SF Mono.
- No custom colors, fonts, views or styling. Appearance, accent color, contrast and accessibility come from macOS.

## Principles

- Use the system component that already does the job before drawing anything.
- Let macOS choose colors: template images in the menu bar, label colors for text, the user's accent color for state.
- Show three things and nothing more: how many agents work, whether the Mac is kept awake, how to stop it.
- Sentence case for every label. Plain words: working, quiet, finished, awake, sleep.

## Menu bar

The status item is one line of text: the number of working agents, the `sparkle` SF Symbol, and the time left on a timed keep-awake, such as `2 ✦ 29m`. The sparkle is a text attachment, so it sits on the text baseline. Text is SF Mono at the menu bar's font size, so the width holds as numbers change, and the menu bar colors it for light and dark.

| State | Shows |
| --- | --- |
| On, nothing to do | `✦` |
| Agents working | `2 ✦` |
| Timed keep-awake running | `2 ✦ 29m`, or `✦ 29m` without agents |
| Off, or paused for battery or heat | The same in the secondary label color |

A text title ignores the button's disabled appearance, so off and paused dim through the color instead.

- Left click turns Until on or off. Right-click or control-click opens the menu, which also opens settings.
- The tooltip and accessibility label read the state and summary, such as "Until is on. 2 agents working, Mac stays awake."

## Menu

A standard NSMenu, top to bottom:

1. The switch: "Until is on", "Until is off" or "Until is paused", with a one-line summary as subtitle and a stock AppKit status image: green on, yellow paused, gray off. Clicking it turns Until on or off. Its image is forced visible, since macOS 27 hides menu item images by default.
2. Agents: a section header and up to 10 agent items, working ones first. More agents go into an "N more" submenu, which macOS scrolls when it gets long; a menu cannot scroll one section on its own. The title is the task: a Claude Code conversation title, else the project folder, else the tool. The subtitle is tool, folder and working or quiet. Each agent has a submenu to stop keeping awake for it, show its folder and see its process and host app.
3. "Stay awake" with a submenu of durations; the running one is checked, its time left is the item's subtitle, and choosing it again stops it. Directly below, "Stay awake when lid is closed" as a checkmark item.
4. App: "About Until" (the standard About window), "Settings…" with Command-comma, "Quit Until" with Command-Q.

## Settings

A standard settings window: NSTabViewController with toolbar tabs and the preference toolbar style. The window title follows the selected tab, and the window takes each tab's height with the tab view controller's stock behavior. Until asks to activate after the click and orders the window to the front. Whether it also takes keyboard focus is macOS's decision; otherwise one click focuses it.

Settings hold only lasting options. Everything used day to day is in the menu.

| Tab | Symbol | Contents |
| --- | --- | --- |
| General | `gearshape` | Login; notifications switch with a checkbox per notification; sleep exceptions for battery and heat |
| Agents | `sparkles` | A toggle per agent, apps, local models, other processes |

Until stays a menu bar app while settings are open: no Dock icon and no Command-Tab entry. Settings come back through the menu. A hidden main menu carries Command-W, Command-Q and editing keys for the settings window.

- General and Agents are SwiftUI grouped Forms. Every section has a header, which also sets the space between sections.
- Section footers are plain text, so the form styles them as secondary notes. An option's own description is the second line of its label, which the form shows under it.
- Option labels say what they let macOS do, in one pattern: "Let Mac sleep when reaching this battery level", "Let Mac sleep when reaching high temperatures".
- Turning off the heat exception asks for confirmation in a standard alert first.
- When macOS has notifications for Until turned off, the notifications section says so and links to System Settings.
- Controls are system toggles, pickers, buttons and text fields, unstyled, in the user's accent color.

## App icon

Plum `#371236` on lavender `#C399FF`, the colors of the first draft. The mark is built like the draft: thick bars, 45° cuts and squares on a unit grid. Three concepts are in `Design/Icon` as SVG and PNG; the hourglass is in the app for now.

The app ships a flat icon in the asset catalog. macOS 27 renders it with glass effects on its own (rim light on the plate, recessed shading on the mark), see `Design/Icon/preview-macos27.png`. Layered variants for dark, clear and tinted appearances need Icon Composer, which comes with Xcode.
