# Contributing to Nonstop Agents

Bug reports, fixes and support for more agents are welcome.

## Report a bug

1. Open Settings, General, Support and click "Copy details".
2. Open a [new issue](https://github.com/marco-vrinssen/NonstopAgents/issues/new) and paste them.
3. Say what you expected, what happened and how to reproduce it.

The details hold versions, the Mac model, the power state and the names of the detected tools. They hold no task titles or folders.

## Add an agent

Agents live in `NonstopAgents/Agents.swift`. Add the executable or script name, then run `./build.sh check --live` while the agent works and while it waits, and say in the pull request what you saw.

## Change the code

1. Read `DESIGN.md`. The app uses native macOS components only.
2. Keep every user-facing string in `NonstopAgents/Localizable.xcstrings` with German, Spanish and French.
3. Run `./build.sh` and `./build.sh check`.
4. For changes to sleep or the lid, say which Mac you tested on and with which power source.

Contributions are licensed under GPL-3.0, like the rest of the code.
