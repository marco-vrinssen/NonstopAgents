# Until design

## In short

- Until is a pure native macOS app. Every element is a system component, an SF Symbol or a system color.
- The menu bar presence is a pill with the number of working agents and the `sparkle` SF Symbol cut out of it, in SF Mono.
- No custom colors, fonts, views or styling. Appearance, accent color, contrast and accessibility come from macOS.

## Principles

- Use the system component that already does the job before drawing anything.
- Let macOS choose colors: template images in the menu bar, label colors for text, the user's accent color for state.
- Show three things and nothing more: how many agents work, whether the Mac is kept awake, how to stop it.
- Sentence case for every label. Plain words: working, quiet, finished, awake, sleep.

## Menu bar

The status item is a pill with the number of working agents, the `sparkle` SF Symbol and the time left on a timed keep-awake cut out of it, such as `2 ✦ 29m`. It is a template image, so the menu bar tints it for light and dark, like the battery icon with its cutout bolt. Text is SF Mono at 12 pt semibold, so the width holds as numbers change. Every part starts on a whole point, so edges stay sharp on 1x displays.

The pill fills the item. macOS pads a menu bar item by 8 pt on each side and, while the menu is open, draws a 24 pt highlight 2 pt past that. The image's alignment rect leaves that padding out, so the 20 pt pill sits 2 pt inside the highlight on every side. On an external display macOS 27 places items 1 pt above the menu bar's center, where it centers the highlight, so the pill moves down by the measured difference inside a taller image. On the built-in display items sit on the center. Until measures the offset from its status window, which spans the menu bar of the display it is on.

| State | Shows |
| --- | --- |
| On, nothing to do | `✦` |
| Agents working | `2 ✦` |
| Timed keep-awake running | `2 ✦ 29m`, or `✦ 29m` without agents |
| Off, or paused for battery or heat | The same, dimmed through the button's disabled appearance |

- Left click turns Until on or off. Right-click or control-click opens the menu, which also opens settings.
- The tooltip and accessibility label read the state and summary, such as "Until is on. 2 agents working, Mac stays awake."

## Menu

A standard NSMenu, top to bottom:

1. The switch: "Until is on", "Until is off" or "Until is paused", with a one-line summary as subtitle and a stock AppKit status image: green on, yellow paused, gray off. Clicking it turns Until on or off. Its image is forced visible, since macOS 27 hides menu item images by default.
2. Agents: a section header and up to 10 agent items, working ones first. More agents go into an "N more" submenu, which macOS scrolls when it gets long; a menu cannot scroll one section on its own. The title is the task: a Claude Code conversation title, else the project folder, else the tool. The subtitle is tool, folder and working or quiet. Each agent has a submenu to stop keeping awake for it, show its folder and see its process and host app.
3. "Stay awake" with a submenu of durations; the running one is checked, its time left is the item's subtitle, and choosing it again stops it. Directly below, "Stay awake when lid is closed" as a checkmark item.
4. "When agents finish": a section header and three checkmark items, "Sleep as usual", "Sleep right away" and "Shut down". The choice applies once, then goes back to "Sleep as usual", and turning Until off cancels it. It waits a minute after the last agent stops, after a timed keep-awake ends and while a Claude Code session waits for an answer. Until holds sleep through that minute; an agent starting its next step cancels the countdown, which the switch's subtitle shows and a notification announces. A Mac that sleeps during the countdown stays asleep. Choosing "Shut down" asks for macOS's Automation permission right away. After a denial its subtitle points to System Settings, and clicking it opens them.
5. App: "About Until" (the standard About window), "Settings…" with Command-comma, "Quit Until" with Command-Q.

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

A four-point sparkle in plum `#371236` on lavender `#C399FF`, drawn for Until. Four curves meet at the tips, 300 pt from the center of the 1024 pt design, and each curve bends toward the center. It echoes the menu bar's `sparkle` without copying it: Apple's terms keep SF Symbols, and glyphs substantially or confusingly similar to them, out of app icons and logos.

- `Design/Icon/AppIcon.svg` is the source: the full-bleed design, with the sparkle as one path.
- `./build.sh icon` renders it into the asset catalog on the macOS icon grid, an 824 pt rounded square inside 1024 pt, at every size. The plate starts on a whole pixel, so its edges stay sharp on 1x displays.
- The About window gets the icon file itself. At runtime macOS offers a single 256 px rendition, which blurs at About's 64 pt.
- macOS 27 adds glass effects to this flat icon on its own. Layered variants for dark, clear and tinted appearances need an Icon Composer file, made in Xcode.
