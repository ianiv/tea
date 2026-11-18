# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tea is a macOS menu bar app (SwiftUI + AppKit, `LSUIElement`, so no Dock icon) that lists every Claude Code session and opens the selected one in Rex, a terminal multiplexer. There is no Xcode project or Swift package: `build.sh` calls `swiftc` directly.

## Commands

```sh
./build.sh             # builds build/Tea.app (arm64, macOS 14+), signed for the team in signing.env or --team, or ad hoc without the widget
./build.sh --team <ID> [--identity <name|->] [--config <file>]   # override signing.env
./build.sh --install   # also copies it to ~/Applications
./build.sh --release   # Developer ID, hardened runtime, timestamp, updater on; not notarized (combines with --install)
pkill -x Tea; open build/Tea.app   # run the new build; `open` would otherwise reuse a running instance
Scripts/release.sh     # build, notarize, staple, zip, EdDSA-sign, add to appcast.xml, create the GitHub release
Scripts/release.sh --local <base-url>   # rehearsal: notarizes, but writes build/release/appcast.xml pointing at <base-url> and touches neither git nor GitHub
                       # both also take --team, --identity, --notary-profile and --config, in any order
```

The build needs a full Xcode toolchain: Command Line Tools lacks the `SwiftUIMacros` plugin, so `@State` fails to compile. If `xcode-select -p` points at `/Library/Developer/CommandLineTools`, prefix the build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. A failed compile still deletes the previous `build/Tea.app`, because `build.sh` removes it before compiling; a signing configuration error doesn't, since that is resolved first.

There are no tests, linter or formatter. To verify a change, build it and check it in the running app.

## Build notes

- App code is in `Sources/Tea.swift`; `Sources/Shared.swift` (`Group`, `Tint`, `AppGroup`, which reads `TeaAppGroup` from the bundle, the widget snapshot types) is compiled into both the app and the widget; `Sources/Widget/TeaWidget.swift` is the widget. `build.sh` names each file in its `swiftc` calls, so a new source file must be added there.
- The desktop widget is `Tea.app/Contents/PlugIns/TeaWidget.appex` (bundle ID `local.ianiv.tea.widget`, `Widget-Info.plist`, whose versions `build.sh` copies from `Info.plist`). It's signed with entitlements generated from `Widget.entitlements` (sandbox + App Group) and the app with ones generated from `Tea.entitlements` (App Group only), inside out and without `--deep`. The widget is linked with `-e _NSExtensionMain`, as Xcode does: with Swift's `_main` as entry point it traps at launch (`ExtensionMain.shared.launchArguments` is nil) and chronod silently drops it from the gallery.
- Signing config: `signing.env` (gitignored; copy `signing.env.example`) is KEY=VALUE, parsed by `Scripts/config.zsh` and never sourced, so nothing in it is expanded or run; an unknown key or malformed line is an error naming the line. The keys are `TEA_TEAM_ID`, `TEA_SIGN_IDENTITY`, `TEA_RELEASE_IDENTITY` and `TEA_NOTARY_PROFILE`. Precedence is CLI flag, then environment, then file, then default, and empty counts as unset. An unset identity is chosen by matching the certificate's subject OU to the team, among identities named `Apple Development: ` (or `Developer ID Application: ` for `--release`); a set identity, by name or SHA-1, gives the team, and a configured team that differs is an error. The parenthesised ID in an Apple Development name is personal, not the team. Signing is by SHA-1, and afterwards the build checks that both bundles carry the expected TeamIdentifier. Dev builds have no hardened runtime or network timestamp, so they work offline.
- App Group: it is `<team>.<CFBundleIdentifier>`. `build.sh` writes it into `build/Tea.entitlements` and `build/TeaWidget.entitlements` (the committed files are templates with an empty group array; plutil key paths split on dots, hence the escaped key), and into both bundles' Info.plist as `TeaAppGroup`, which `AppGroup.id` reads. It needs no provisioning profile, because macOS authorizes a team-prefixed group by the signature's TeamIdentifier.
- Fallbacks: with no team or identity configured, or `--identity -`, the build is ad hoc with no widget, no entitlements and no `TeaAppGroup`, so `AppGroup.id` is nil and `WidgetExporter.isAvailable` is false (touching the group container unentitled would prompt). A configured team or identity that can't be satisfied is an error, never a quiet ad-hoc build. `--release` requires a team and has no fallback; it adds `--options runtime --timestamp` (the timestamp needs the network).
- Only the installed copy's widget is registered: `--install` runs `pluginkit -a` on it, and a plain build runs `pluginkit -r` on the `build/` copy, so the widget gallery doesn't list two.
- `Resources/AppIcon.icns` is generated from `Scripts/make-icon.swift`, and only rebuilt when the script is newer than the `.icns`. `Tea-icon.png` is not used by the build.
- Sparkle (version and sha256 pinned in `build.sh`) is downloaded once into the gitignored `.deps/`, checksummed and extracted to `.deps/sparkle-<version>`, with a `.deps/sparkle` symlink that `Scripts/release.sh` uses for `sign_update`. This happens before `build/Tea.app` is deleted; to build offline, seed the cache by copying `Sparkle-<version>.tar.xz` into `.deps/`. The sha256 is checked only when the tarball is downloaded and extracted, not on every build, so delete `.deps/` to force a recheck. The app is compiled with `-F .deps/sparkle-<version> -framework Sparkle` and an `@executable_path/../Frameworks` rpath, and every build mode embeds the framework in `Contents/Frameworks`, minus its XPC services (Tea isn't sandboxed). That removal breaks the framework's seal, so every mode re-signs it, inside out without `--deep`: `Autoupdate`, `Updater.app`, the framework, then the widget and the app. Under hardened runtime this also gives Sparkle the app's team, which library validation requires.
- `Info.plist` is copied as is, except that `--release` inserts `TeaChecksForUpdates`, which the app reads to decide whether to start Sparkle. The version is set by hand there. It also holds `SUFeedURL` (raw `appcast.xml` on `main`), `SUPublicEDKey` and `SUVerifyUpdateBeforeExtraction`; `SUEnableAutomaticChecks` is deliberately unset, so Sparkle asks on the second launch.

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

Updates: `AppDelegate.updater` is Sparkle's `SPUStandardUpdaterController`, created only when `Info.plist` has `TeaChecksForUpdates` (release builds). Dev, ad-hoc and release builds share the bundle ID and so the `local.ianiv.tea` defaults, including Sparkle's `SU*` keys: if dev builds ran the updater, one behind the latest release would offer to replace itself, so they embed Sparkle but never start it. A `SUFeedURL` written to those defaults overrides `Info.plist`, which is how a local feed is tested; delete it afterwards. With the updater on, "Check for Updates…" appears in both the options menu (`ContentView.header`, through `AppDelegate.checkForUpdates()`, which closes the popover first) and the status item's right-click menu (`statusMenu()`). `AppDelegate` is the `SPUStandardUserDriverDelegate` and opts into gentle scheduled reminders, as an `LSUIElement` app.

The UI is a popover from the status item, which can detach into a window. Both host the same `ContentView` (`Mode` differs) and share one store. The menu bar badge counts the Needs input and Ready for review rows.

The desktop widget reads a snapshot (`TeaSnapshot`, JSON in the App Group container) that `WidgetExporter` writes from `store.$rows`, like the badge but from the first refresh on: the Needs input, Ready for review and Working rows, in Tea's order. A change in counts or group membership reloads the widget at once; an activity-only change reloads at most once a minute (with a trailing reload); an unchanged snapshot is rewritten about once a minute without a reload, and the widget shows "Tea isn't running" once it's over 20 minutes old. Since the heartbeat doesn't reload, the widget only rereads the file on its own 15-minute timeline reload, so "Updated N ago" counts from the snapshot read at the last reload and can show up to about 16 minutes while Tea runs, and a stopped Tea is noticed within about 20 minutes. The widget links back through the `tea` URL scheme (`Info.plist`), handled in `AppDelegate.application(_:open:)`: `tea://open` shows the list, `tea://session/<sessionId>` opens that row as a click would, and `tea://top/blocked|review` opens the newest row in that group; a missing row or a notice shows the popover.

## Releasing

1. Bump `CFBundleShortVersionString` (like `1.2.3`; names the tag `v<short>` and `Tea-<short>.zip`) and `CFBundleVersion` (an integer, one higher every release, which is what Sparkle compares) in `Info.plist`, commit, and push to `main`.
2. Run `Scripts/release.sh` from a clean checkout at `origin/main`. Before building, it refuses if the tag or release exists, the version isn't newer than everything in `appcast.xml`, or the keychain's Sparkle key doesn't match `SUPublicEDKey`. It needs `TEA_TEAM_ID` (in `signing.env` or `--team`) and that team's Developer ID identity in the keychain, the notarytool keychain profile (`TEA_NOTARY_PROFILE`, default `tea-notary`, checked before building), Sparkle's EdDSA private key in the login keychain (back it up with `.deps/sparkle/bin/generate_keys -x <file>`: with `SUVerifyUpdateBeforeExtraction`, losing it means installed copies can't verify any later update), and a logged-in `gh`. After notarizing, it checks that both bundles carry that TeamIdentifier and App Group.
3. It builds the new feed in `build/release/`, creates the GitHub release, and only then copies the feed over `appcast.xml` and prints its commit-and-push. Push it only after the release exists, or clients would get a 404 for the zip; if `gh release create` fails, `appcast.xml` is left untouched. raw.githubusercontent caches for about 5 minutes, so clients may see the new item a little later.

## Conventions and gotchas

- `Group` is Tea's model enum (in `Shared.swift`) and shadows `SwiftUI.Group`; write `SwiftUI.Group` if you need the view.
- Finder-launched apps get a minimal `PATH`, so `Tools` looks up `claude` and `rex` at known absolute paths and `Tools.environment` extends `PATH` for child processes. Run subprocesses through `run()`, which also enforces a timeout.
- `@AppStorage` inside `AgentStore` doesn't trigger view updates by itself, which is why `toggleCollapsed` calls `objectWillChange.send()`.
- The app used to be "Claude Agents" (`local.ianiv.claude-agents`). `migrateDefaults()` copies its settings once, and it only needs the keys that existed then.
