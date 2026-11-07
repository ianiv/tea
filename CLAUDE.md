# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tea is a macOS menu bar app (SwiftUI + AppKit, `LSUIElement`, so no Dock icon) that lists every Claude Code session and opens the selected one in Rex, a terminal multiplexer. There is no Xcode project or Swift package: `build.sh` calls `swiftc` directly.

## Commands

```sh
./build.sh             # builds build/Tea.app (arm64, macOS 14+, ad-hoc signed)
./build.sh --install   # also copies it to ~/Applications
pkill -x Tea; open build/Tea.app   # run the new build; `open` would otherwise reuse a running instance
```

There are no tests, linter or formatter. To verify a change, build it and check it in the running app.

## Build notes

- All app code is in `Sources/Tea.swift`. `build.sh` names that file explicitly, so a new source file must be added to its `swiftc` call.
- `Resources/AppIcon.icns` is generated from `Scripts/make-icon.swift`, and only rebuilt when the script is newer than the `.icns`. `Tea-icon.png` is not used by the build.
- `Info.plist` is copied as is, and the version is set by hand there.

## Architecture

`AgentStore` polls every 2 seconds (`refresh()`, which skips a tick if one is still running) and rebuilds `rows`. Each `Row` combines these sources:

| Source | Provides |
| --- | --- |
| `claude agents --json --all` | The session list (`Agent`) |
| `~/.claude/sessions/<pid>.json` | Raw live status, and `entrypoint`, used to hide Agent SDK sessions (`sdk*`) |
| `~/.claude/jobs/<id>/state.json` | Background job state, tempo, summary, linked PRs (`Job`) |
| `~/.claude/gh-pr-status-cache.json` | PR state, checks and review (`PRStatus`) |
| `rex ls`, `rex api call session.view`, `rex block call process` / `program_status`, `ps` | Rex panes, their foreground process, and Claude's program status (`RexBlock`) |

These are other programs' internal formats, parsed loosely with `JSONSerialization`. A missing field generally degrades the row rather than raising an error, so a format change can look like wrong grouping.

Key logic:

- **`makeRow`** decides both a row's `Group` (the list section) and its `Activity` (the card's status line). `Group` deliberately mirrors how the `claude agents` view groups sessions, including its rules in `Job.terminal` and `PRStatus.health` / `needsReview`, so keep it consistent with that view. `idle` is Tea's only addition.
- **Rex status overrides session status**: only Rex's record knows a session is waiting on a permission, so a `blocked` record forces `waiting`.
- **`liveStatus` prefers the session file** over `claude agents --json`, which reports `shell` as `busy`.
- **`findBlock`** matches a session to a Rex pane by foreground pid, then by argv (`claude attach <id>` or the session ID). The pid match only applies to live sessions, because a finished session's pid may have been reused.
- **`open`** has three outcomes: focus the existing pane; open a new tab in the target Rex session running `claude attach <id>` (background agents); or show a notice, because interactive sessions outside Rex can't be taken over.

The UI is a popover from the status item, which can detach into a window. Both host the same `ContentView` (`Mode` differs) and share one store. The menu bar badge counts the Needs input and Ready for review rows.

## Conventions and gotchas

- `Group` is Tea's model enum and shadows `SwiftUI.Group`; write `SwiftUI.Group` if you need the view.
- Finder-launched apps get a minimal `PATH`, so `Tools` looks up `claude` and `rex` at known absolute paths and `Tools.environment` extends `PATH` for child processes. Run subprocesses through `run()`, which also enforces a timeout.
- `@AppStorage` inside `AgentStore` doesn't trigger view updates by itself, which is why `toggleCollapsed` calls `objectWillChange.send()`.
- The app used to be "Claude Agents" (`local.ianiv.claude-agents`). `migrateDefaults()` copies its settings once, and it only needs the keys that existed then.
