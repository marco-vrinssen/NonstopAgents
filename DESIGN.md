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

The status item shows the `sparkle` SF Symbol exactly as macOS provides it, so the menu bar sizes and tints it like its own icons. While agents work, their number follows it in SF Mono at the menu bar's font size, so the width does not jitter as the count changes.

| State | Shows |
| --- | --- |
| On, no agent working | Sparkle |
| On, agents working | Sparkle and the count |
| Off, or paused for battery or heat | The same, with the disabled appearance |

- Left click turns Until on or off. Right-click or control-click opens the menu, which also opens settings.
- The tooltip and accessibility label read the state and summary, such as "Until is on. 2 agents working, Mac stays awake."

## Menu

A standard NSMenu, top to bottom:

1. The switch: "Until is on", "Until is off" or "Until is paused", with a one-line summary as subtitle. A stock AppKit status image shows the state: green when on, yellow when paused, gray when off. Clicking it turns Until on or off. Its image is forced visible, since macOS 27 hides menu item images by default.
2. Agents: a section header, then one item per agent process, working ones first. The title is the task: a Claude Code conversation title, else the project folder, else the tool. The subtitle is tool, folder and working or quiet. Each agent has a submenu to stop keeping awake for it, show its folder and see its process and host app.
3. Actions: "Keep awake for" with durations, "Stay awake with lid closed" as a checkmark item.
4. App: "Settings…" with Command-comma, "Quit Until" with Command-Q.

## Settings

A standard settings window: NSTabViewController with toolbar tabs and the preference toolbar style. The window title follows the selected tab, and the window takes each tab's height with the tab view controller's stock behavior. Until asks to activate after the click and orders the window to the front. Whether it also takes keyboard focus is macOS's decision; otherwise one click focuses it.

Settings hold only lasting options. Everything used day to day is in the menu.

| Tab | Symbol | Contents |
| --- | --- | --- |
| General | `gearshape` | Open at login, notifications, battery limit, heat |
| Agents | `sparkles` | A toggle per agent, apps, local models, other processes |
| About | `info.circle` | Icon, name, version, copyright |

While settings are open Until is a regular app: it shows in the Dock and in Command-Tab, with the standard app, File, Edit and Window menus. Closing settings returns it to the menu bar only.

- General and Agents are SwiftUI grouped Forms. Every section has a header, which also sets the space between sections. About is a centered stack like the standard about panel.
- Section footers are plain text, so the form styles them as secondary notes.
- Controls are system toggles, pickers, buttons and text fields, unstyled, in the user's accent color.

## App icon

A dark rounded square with a white dot.
