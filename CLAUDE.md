# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tea is a macOS menu bar app (SwiftUI + AppKit, `LSUIElement`, so no Dock icon) that lists every Claude Code session and opens the selected one in Rex, a terminal multiplexer. There is no Xcode project or Swift package: `build.sh` calls `swiftc` directly.

## Commands

```sh
./build.sh             # builds build/Tea.app (arm64, macOS 14+, signed with `TEA_SIGN_IDENTITY`, or ad hoc without the widget)
./build.sh --install   # also copies it to ~/Applications
pkill -x Tea; open build/Tea.app   # run the new build; `open` would otherwise reuse a running instance
```

The build needs a full Xcode toolchain: Command Line Tools lacks the `SwiftUIMacros` plugin, so `@State` fails to compile. If `xcode-select -p` points at `/Library/Developer/CommandLineTools`, prefix the build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. A failed build still deletes the previous `build/Tea.app`, because `build.sh` removes it before compiling.

There are no tests, linter or formatter. To verify a change, build it and check it in the running app.

## Build notes

- App code is in `Sources/Tea.swift`; `Sources/Shared.swift` (`Group`, `Tint`, `AppGroup`, the widget snapshot types) is compiled into both the app and the widget; `Sources/Widget/TeaWidget.swift` is the widget. `build.sh` names each file in its `swiftc` calls, so a new source file must be added there.
- The desktop widget is `Tea.app/Contents/PlugIns/TeaWidget.appex` (bundle ID `local.ianiv.tea.widget`, `Widget-Info.plist`, whose versions `build.sh` copies from `Info.plist`). It's signed with `Widget.entitlements` (sandbox + App Group) and the app with `Tea.entitlements` (App Group only), inside out and without `--deep`.
- Signing uses `TEA_SIGN_IDENTITY`, defaulting to `Apple Development: Ianiv Schweber (66J53X6839)`. The App Group `7EN8DG9MKN.local.ianiv.tea` needs no provisioning profile: macOS authorizes a team-prefixed group by the signature's TeamIdentifier (`7EN8DG9MKN`, not the identity's `66J53X6839`). If the identity isn't in the keychain, or `TEA_SIGN_IDENTITY=-`, the build warns and falls back to an ad-hoc app with no widget and no entitlements; the app then skips the snapshot (`WidgetExporter.isAvailable`), since touching the group container unentitled would prompt.
- Only the installed copy's widget is registered: `--install` runs `pluginkit -a` on it, and a plain build runs `pluginkit -r` on the `build/` copy, so the widget gallery doesn't list two.
- `Resources/AppIcon.icns` is generated from `Scripts/make-icon.swift`, and only rebuilt when the script is newer than the `.icns`. `Tea-icon.png` is not used by the build.
- `Info.plist` is copied as is, and the version is set by hand there.

## Architecture

`AgentStore` polls every 2 seconds while the list is on screen and every 15 seconds otherwise (`refresh()`, which skips a tick if one is still running; `refreshNow()`, used by URL handling, awaits the running refresh or starts one), and rebuilds `rows`. Each refresh's child processes count toward Tea's energy use in macOS. Each `Row` combines these sources:

| Source | Provides |
| --- | --- |
| `~/.claude/sessions/<pid>.json` | Running sessions (`Agent`, via `SessionFiles`): raw live status, and `entrypoint`, used to hide Agent SDK sessions (`sdk*`) |
| `~/.claude/projects/*/<sessionId>.jsonl` | The latest `custom-title` / `ai-title`, shown instead of a `derived` (folder placeholder) name so cards match the Rex tab (`TranscriptTitles`). A tab the user named in Rex (`RexBlock.tabName`) wins over both |
| `~/.claude/jobs/<id>/state.json` | Background jobs (`Agent`), and their state, tempo, summary, linked PRs (`Job`) |
| `~/.claude/gh-pr-status-cache.json` | PR state, checks and review (`PRStatus`) |
| `rex ls`, `rex api call session.view`, `rex block call process` / `program_status`, `ps` | Rex panes, their foreground process, and Claude's program status (`RexBlock`) |

These are other programs' internal formats, parsed loosely with `JSONSerialization`. A missing field generally degrades the row rather than raising an error, so a format change can look like wrong grouping.

Key logic:

- **`makeRow`** decides both a row's `Group` (the list section) and its `Activity` (the card's status line). `Group` deliberately mirrors how the `claude agents` view groups sessions, including its rules in `Job.terminal` and `PRStatus.health` / `needsReview`, so keep it consistent with that view. `idle` is Tea's only addition.
- **Rex status overrides session status**: only Rex's record knows a session is waiting on a permission, so a `blocked` record forces `waiting`.
- **`SessionFiles` replaces `claude agents --json --all`**, so a refresh no longer starts the CLI (about 150 MB and 1B instructions). It copies the CLI's rules: a session file counts only if its pid is still the process that wrote it (`procStart`); a job's process (`jobId`) becomes the job's row; a terminal parked onto a job (`parkedJobId`) is hidden. If the CLI's list and Tea's differ, look here. It also keeps the raw `shell` status, which the CLI reports as `busy`.
- **`findBlock`** matches a session to a Rex pane by foreground pid, then by argv (`claude attach <id>` or the session ID). The pid match only applies to live sessions, because a finished session's pid may have been reused. A session attached inside a `claude agents` pane matches neither, so as a last resort the pane's terminal title (minus Claude's leading status glyph) is matched to the session name (`RexBlock.attachedName`).
- **`open`** has three outcomes: focus the existing pane; open a new tab running `claude attach <id>` in the chosen Rex session (background agents), or until one is chosen in a session named `Claude`, created if needed; or show a notice, because interactive sessions outside Rex can't be taken over.
- **`newSession`** (the header's + menu) runs a plain `claude` in a recent session folder, Home, or a chosen folder, through the same `openNewTab` placement as a background agent.

The UI is a popover from the status item, which can detach into a window. Both host the same `ContentView` (`Mode` differs) and share one store. The menu bar badge counts the Needs input and Ready for review rows.

The desktop widget reads a snapshot (`TeaSnapshot`, JSON in the App Group container) that `WidgetExporter` writes from `store.$rows`, like the badge but from the first refresh on: the Needs input, Ready for review and Working rows, in Tea's order. A change in counts or group membership reloads the widget at once; an activity-only change reloads at most once a minute (with a trailing reload); an unchanged snapshot is rewritten about once a minute without a reload, and the widget shows "Tea isn't running" once it's over 20 minutes old. Since the heartbeat doesn't reload, the widget only rereads the file on its own 15-minute timeline reload, so "Updated N ago" counts from the snapshot read at the last reload and can show up to about 16 minutes while Tea runs, and a stopped Tea is noticed within about 20 minutes. The widget links back through the `tea` URL scheme (`Info.plist`), handled in `AppDelegate.application(_:open:)`: `tea://open` shows the list, `tea://session/<sessionId>` opens that row as a click would, and `tea://top/blocked|review` opens the newest row in that group; a missing row or a notice shows the popover.

## Conventions and gotchas

- `Group` is Tea's model enum (in `Shared.swift`) and shadows `SwiftUI.Group`; write `SwiftUI.Group` if you need the view.
- Finder-launched apps get a minimal `PATH`, so `Tools` looks up `claude` and `rex` at known absolute paths and `Tools.environment` extends `PATH` for child processes. Run subprocesses through `run()`, which also enforces a timeout.
- `@AppStorage` inside `AgentStore` doesn't trigger view updates by itself, which is why `toggleCollapsed` calls `objectWillChange.send()`.
- The app used to be "Claude Agents" (`local.ianiv.claude-agents`). `migrateDefaults()` copies its settings once, and it only needs the keys that existed then.
