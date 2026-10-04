---
version: 1.0
name: Until
description: "A single dot in the macOS menu bar that counts working AI agents and keeps the Mac awake until they finish. Adapted from Linear's design language: one lavender accent, a quiet neutral base, hairlines before boxes, and type that carries the hierarchy. Until lives inside macOS chrome, so Linear's literal surfaces map onto system colors in the app and stay literal only in the icon and on the website."

colors:
  accent: "#5E6AD2"
  accent-dark: "#828FFF"
  canvas: "#010102"
  surface-1: "#0F1011"
  surface-2: "#141516"
  hairline: "#23252A"
  ink: "#F7F8F8"
  ink-subtle: "#8A8F98"
  ink-tertiary: "#62666D"
  inverse-canvas: "#FFFFFF"
  inverse-ink: "#000000"

system-colors:
  canvas: windowBackgroundColor
  surface: controlBackgroundColor
  hairline: separatorColor
  ink: labelColor
  ink-subtle: secondaryLabelColor
  ink-tertiary: tertiaryLabelColor

typography:
  family: "SF Pro, the system font"
  headline:
    size: 13pt
    weight: 600
  body:
    size: 13pt
    weight: 400
  caption:
    size: 11pt
    weight: 400
  dot-digit:
    size: 10.5pt
    weight: 700
    features: monospaced digits

spacing:
  base: 4pt
  steps: [4, 8, 12, 16, 24, 32]
  menu-inset: 15pt

rounded:
  dot: full
  card: 12pt
  control: 8pt

components:
  menu-bar-dot:
    height: 15pt
    small-dot: 9pt
    ring-stroke: 1.5pt
    capsule-padding: 4pt
    dimmed-alpha: 0.45
    rendering: template image, digits cut out of the fill
  agent-state-dot:
    size: 8pt
    working: accent fill
    quiet: 1.5pt ring in ink-tertiary
  menu-header:
    title: headline
    detail: caption in ink-subtle
    padding: 15pt horizontal, 6pt vertical
    width: 260pt
  settings-window:
    size: 480 x 600pt
    style: grouped form, two tabs
    tint: accent
---

# Until design

## In short

- One dot in the menu bar. Filled means the Mac is kept awake, the number inside counts working agents.
- One accent, Linear lavender, and only for state and controls. Everything else is the macOS neutral base.
- Hierarchy comes from type size and weight, separation from space and hairlines.
- Native macOS chrome first. Until borrows Linear's restraint, not its dark marketing canvas.

## Principles

Until is passive. It earns trust by being right and by staying out of the way, so the interface says three things and nothing more: how many agents are working, whether the Mac is kept awake, and how to stop it.

- Content first. The count and the state are the product. Every other element must help read them.
- Linear's single-accent rule holds. Lavender marks working state and control tint, never decoration.
- Linear's surface ladder becomes the system's semantic colors, so Until follows light mode, dark mode, wallpaper tinting and increased contrast without custom work.
- Linear's hairline-over-shadow rule holds. Separators split the menu, grouped form sections split the settings.
- No gradients, glows, textures or illustrations. Motion is the system's own menu and window animation.

## Colors

The accent has two values. Lavender `#5E6AD2` is Linear's primary on light surfaces. On dark surfaces Until uses Linear's lighter hover tone `#828FFF`, which keeps a 3:1 contrast against dark menu materials.

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| Accent | `#5E6AD2` | `#828FFF` | Working agent dot, control tint |
| Ink | labelColor | labelColor | Titles |
| Ink subtle | secondaryLabelColor | secondaryLabelColor | Details, footers |
| Ink tertiary | tertiaryLabelColor | tertiaryLabelColor | Quiet agent ring |
| Hairline | separatorColor | separatorColor | Menu separators |

The menu bar dot uses no color at all. It is a template image, so macOS draws it black or white to match the bar, the wallpaper tint and the highlighted state.

Linear's literal dark values stay in use in two places: the app icon (`surface-1` plate, `hairline` edge, `accent` dot) and the future website, where Linear's canvas `#010102` and surface ladder apply as written.

## Typography

SF Pro, the system font, which is also Linear's documented fallback. Two weights carry the interface: regular 400 and semibold 600.

| Token | Size | Weight | Use |
| --- | --- | --- | --- |
| headline | 13pt | 600 | Menu header title |
| body | 13pt | 400 | Menu items, settings labels |
| caption | 11pt | 400 | Header detail, agent subtitles, settings footers |
| dot-digit | 10.5pt | 700 | Count inside the dot |

The dot digit is the one exception to two weights. Cut-out strokes thin out at menu bar size, so the count is bold and uses monospaced digits so the dot does not change width between 1 and 9.

## Layout

A 4pt base unit, Linear's grid, with 8pt steps for most spacing.

- Menu header: 15pt side inset to align with the system section headers, 6pt top and bottom, 2pt between title and detail.
- Settings: grouped form at 480 by 600pt, the macOS default section spacing, footers directly under their section.
- Whitespace separates first, a hairline second, a grouped section box last.

## Components

### Menu bar dot

The whole menu bar presence. It grows to hold a number and shrinks back to a small dot.

| State | Shape | Meaning |
| --- | --- | --- |
| Idle | 9pt ring | Until is on, no agent works, the Mac sleeps as usual |
| Working | 15pt filled dot, count cut out | Agents work, the Mac is kept awake |
| Holding | 9pt filled dot | Agents just finished or a manual keep-awake runs |
| Off | 9pt ring at 45% | Until is off |
| Off with agents | 15pt ring at 45%, count inside | Agents work but Until will not keep the Mac awake |
| Paused | Same as off | Battery floor reached or the Mac runs hot |

- Two or more digits turn the circle into a capsule with 4pt padding. Counts above 99 read `99+`.
- Digits are cut out of the fill, not drawn on it. The menu bar shows through, which keeps them legible in light and dark bars at 1x and 2x.
- Left click turns Until on or off. Right click or control-click opens the menu. Settings can swap the two, as Amphetamine allows.
- The tooltip and the VoiceOver label read the menu header, for example "Until: 2 agents working. Your Mac stays awake."

### Menu

A native NSMenu, so it inherits the system material, keyboard navigation and accessibility. Order follows importance:

1. Header: headline and one line of detail, such as "2 agents working" over "Awake, also with the lid closed".
2. Agents: a section header, then one row per agent process.
3. Actions: "Keep awake for" with durations, and "Stay awake with lid closed" as a checkmark item.
4. Control: "Turn Until off" with the hint "Or click the dot", then "Settings…" and "Quit Until".

### Agent rows

- Title: the tool name, such as Claude Code or Codex.
- Subtitle in caption style: folder, host app and state, joined by middle dots. Example: `until-app · Warp · working`.
- State dot, 8pt: accent fill when working, a 1.5pt tertiary ring when quiet or ignored.
- Working agents sort first, then by start time.
- The submenu holds "Keep awake for this agent", "Show folder in Finder" and the process id with its start time.

### Settings window

Two tabs. General holds behavior, Agents holds detection.

- General: on or off, open at login, left click behavior, time after agents finish, display, lid closed, battery floor, safety and notifications.
- Agents: one toggle per known agent, local models, and custom process names.
- Every section footer explains the consequence in one or two plain sentences.
- Controls take the accent as tint. No other color appears.

## Copy

- Sentence case for every label, button and menu item.
- Plain words: working, quiet, finished, awake, sleep. No jargon such as assertion or clamshell in the interface.
- Short declaratives. A footer says what happens, not how it is built.
- Numbers as digits, times as `2 min` and `1 h 5 min`, battery as `20%`.

## Do

- Keep the dot monochrome and let macOS tint it.
- Use the accent only for the working state and for control tint.
- Use system semantic colors inside the app so appearance changes need no extra work.
- Explain every safety behavior where the user turns it on.

## Don't

- Don't add a second accent, color the menu bar dot, or use red and green for state.
- Don't draw custom backgrounds behind native menus or forms.
- Don't animate the dot. A state change swaps the image.
- Don't show agents that merely exist as working. Quiet is a state, not an error.
