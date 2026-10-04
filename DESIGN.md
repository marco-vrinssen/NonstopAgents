# Until design

## In short

- Until is a pure native macOS app. Every element is a system component, an SF Symbol or a system color.
- The menu bar presence is one SF Symbol: a circle that shows the number of working agents.
- No custom colors, fonts, views or styling. Appearance, accent color, contrast and accessibility come from macOS.

## Principles

- Use the system component that already does the job before drawing anything.
- Let macOS choose colors: template images in the menu bar, label colors for text, the user's accent color for state.
- Show three things and nothing more: how many agents work, whether the Mac is kept awake, how to stop it.
- Sentence case for every label. Plain words: working, quiet, finished, awake, sleep.

## Menu bar

The status item shows an SF Symbol 15 pt tall (12 pt, semibold), the size of the system's own menu bar icons. The numbered circle symbols cut the digit out of the fill, and macOS tints them for light and dark menu bars and for the highlighted state. The symbol is redrawn as a plain template image, because symbols lay out on their text baseline and the status bar would crop the circle.

| State | Symbol | Meaning |
| --- | --- | --- |
| Idle | `circle` | Until is on, no agent works, the Mac sleeps as usual |
| Working | `1.circle.fill` to `50.circle.fill` | Agents work, the Mac is kept awake |
| Many agents | `ellipsis.circle.fill` | More than 50 agents work |
| Holding | `circle.fill` | Agents just finished, or a manual keep-awake runs |
| Off or paused | `circle` or `2.circle`, disabled appearance | Until is off, or paused for battery or heat |
| Failed | `exclamationmark.circle` | macOS declined to keep the Mac awake |

- Left click turns Until on or off. Right-click or control-click opens the menu. Settings can swap the two.
- The tooltip and accessibility label read the status line, such as "Until: 2 agents working. Your Mac stays awake."

## Menu

A standard NSMenu, top to bottom:

1. Status: a disabled item with the headline as title and the detail as subtitle.
2. Agents: a section header, then one item per agent process. Title is the tool, subtitle is folder, host app and state. The image is `circle.fill` in the system accent color when working, `circle` in secondary label color when quiet. Each agent has a submenu to stop keeping awake for it, show its folder and see its process.
3. Actions: "Keep awake for" with durations, "Stay awake with lid closed" as a checkmark item.
4. Control: "Turn Until off" with the subtitle "Or click the dot".
5. App: "About Until" (the standard about panel), "Settings…" with Command-comma, "Quit Until" with Command-Q.

## Settings

A standard settings window: NSTabViewController with toolbar tabs and the preference toolbar style. The window title follows the selected tab, and the window takes each tab's height. It opens as the frontmost window: Until activates after its menu closes and orders the window above other apps.

| Tab | Symbol | Contents |
| --- | --- | --- |
| General | `gearshape` | On or off, open at login, left click, notifications |
| Power | `bolt` | Time after agents finish, display, lid closed, battery, heat |
| Agents | `sparkles` | A toggle per agent, apps, local models, other processes |

- Each tab is one SwiftUI grouped Form. Every section has a header, which also sets the space between sections.
- Section footers are plain text, so the form styles them as secondary notes.
- Controls are system toggles, pickers, sliders, buttons and text fields in the user's accent color.

## App icon

A dark rounded square with a white dot, the menu bar circle at app icon size.
