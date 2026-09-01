# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and test

All logic lives in the local `ChronicleKit` package, so the package tests are the fast loop:

```sh
swift test --package-path ChronicleKit                       # all package tests
swift test --package-path ChronicleKit --filter StoreTests   # one suite
swift test --package-path ChronicleKit --filter StoreTests/cursorDeliveryIsDurableOrderedAndDeduplicated
```

App-level targets build through Xcode:

```sh
xcodebuild build -project Chronicle.xcodeproj -scheme Chronicle \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO                                    # what CI builds

xcodebuild test -project Chronicle.xcodeproj -scheme Chronicle \
  -destination 'platform=macOS'                              # ChronicleTests (app-target rendering/editor tests)
```

Schemes: `Chronicle` (app), `ChronicleCLI` (CLI target), `ChronicleKit`, `ChronicleCLICore`.
Tests use swift-testing (`@Suite`/`@Test`/`#expect`), not XCTest.

Always run against an isolated data root when exercising the CLI or store by hand — otherwise
you write into the real app home:

```sh
CHRONICLE_APP_HOME=/tmp/chronicle-dev swift run --package-path ChronicleKit ...
```

`CHRONICLE_APP_HOME` overrides `~/Library/Application Support/Chronicle`; `CHRONICLE_HOME`
overrides the IDE plugin's read-only publish root (`~/.chronicle`); `TUPLE_BIN` overrides Tuple
CLI discovery. `ChronicleKit/Tests/.../TestSupport.swift` provides `TestHome`, a git-repo
factory, and shell-script Tuple mocks — new tests should build on those rather than touching
real home directories.

## Architecture

Three build products from one Xcode project:

- **Chronicle.app** — SwiftUI (macOS 26+, unsandboxed, hardened runtime), Sparkle for updates.
- **chronicle** — CLI embedded at `Chronicle.app/Contents/Helpers/chronicle`; `ChronicleCLI/main.swift`
  is a two-line shim over `ChronicleCLICore` so command behavior is testable as a library.
- **ChronicleKit** — every piece of logic: models, paths, GRDB store, Tuple client, IDE ingestion,
  collector, git helpers, skill installer, handoff markdown model.

**No daemon and no IPC.** The GUI and the CLI are separate processes that coordinate *only*
through the SQLite database (WAL, busy timeout, IMMEDIATE transactions) plus advisory file locks
under `<app home>/locks/`. CLI writes must keep working with the GUI closed; never introduce a
socket, XPC service, or "GUI is authoritative" assumption.

Data flow: `Collector.collectOnce` is the single collection pass, run both by the GUI's
background loop and by every CLI `show`/`session` command. It polls `tuple call current`,
collects Tuple transcription under a lock, then discovers and tails the IDE plugin's JSONL log.
Everything normalizes into `source_events`; `ChronicleStore.show` hands each consumer its
undelivered events exactly once via `consumer_cursors`/`consumer_deliveries` in one transaction
— ordered by `occurred_at`, not insertion order, so late-arriving events still deliver.

The GUI never reads sources directly: `ChronicleStore.snapshot()` builds an `AppSnapshot`
(mode, markdown, messages, source health, sessions, IDE candidates) and `AppModel` renders it,
refreshing from GRDB `ValueObservation` plus a `DispatchSource` watch on `notes.md`.

Claude Code participates through the installed skill (`ChronicleKit/Sources/ChronicleKit/Resources/SKILL.md`,
`{{CHRONICLE_BIN}}` substituted at install) invoking the CLI at the `~/.chronicle/bin/chronicle`
shim. Room feedback flows back as *synthetic events* (`decision_approved`, `decision_rejected`,
`reference_stale`) that appear in the skill's next `show` — that is the only reverse channel.

### Naming trap: three meanings of "chronicle"

- `SourceHealth.source` values are `tuple`, `claude`, `chronicle` — where **`chronicle` means the
  IDE plugin**, shown to the skill and the UI.
- `NormalizedEvent.source` values are `tuple`, `ide` (imported plugin events), and `chronicle`
  (synthetic review events emitted by this app).
- The product name also covers the app, the CLI, and the plugin.

These names are contract surface for the skill. Do not "clean them up."

### Invariants worth knowing before editing

- The Tuple call ID **is** the session ID. Session directories use `ChroniclePaths.safeSessionId`.
- Only the CLI may start a session from a detected call (`collectOnce(startSessions:)` defaults to
  true); the GUI collector passes `false` and merely records the available call, so being open
  during a call never creates a session on its own.
- The IDE plugin's root is strictly read-only: never write, move, or delete anything under it.
- The IDE **log** is fail-closed (unknown event types or `data` keys are errors, and a failure
  preserves the previous cursor); the `sessions.json` **registry** is deliberately tolerant of
  unknown fields.
- Nothing reaches a user's project except an explicit Save As… of the handoff. No transcript,
  chat, event, or notes sidecars — anywhere.
- Every stored/emitted timestamp goes through the shared formatter in `Timestamps.swift`:
  UTC RFC 3339 with exactly three fractional digits.
- CLI output contract: exit 0 with JSON/text on stdout, exit 1 with `chronicle: <message>` on
  stderr. Command names, flags, and error strings are consumed by the skill — changing one means
  changing `SKILL.md`, `docs/SPEC.md` §4, and `CommandTests.swift` together.
- Decisions are a `decision` chat message + a `decision_reviews` row + an invisible
  `<!-- chronicle-decision: id -->` marker in the markdown. There is no separate note or task entity.
- Retention prunes old terminal sessions but protects any handoff that was never saved externally
  (`saved_hash` vs. current content hash); pruned sessions return empty from `show` forever.

### Markdown rendering split

`HandoffDocument` (ChronicleKit) is the pure model: strips HTML comments, extracts blocks with
heading paths and anchors, decision markers, and inline file references. `Chronicle/HandoffText.swift`
builds the AppKit attributed-string rendering plus the source↔rendered maps used for anchor
scrolling, snippet highlighting, and Copy as Markdown. Keep parsing in the package and
presentation in the app.

## Docs and design contract

- `docs/SPEC.md` — the authoritative product/architecture spec; it is the porting contract from
  the earlier Tauri prototype ("scribe") and specifies exact behaviors, error strings, and schema.
  Consult it before changing store, collector, CLI, or ingestion behavior.
- `docs/UI-DESIGN.md` — the SwiftUI design contract: window anatomy, exact banner/waiting-state
  copy, command and menu plan, QA checklist.
- `docs/ide-wire-contract.md` — the IDE plugin's registry and log format.
- `docs/RELEASING.md` — signing, notarization, Sparkle keys, tag-driven release.

UI work follows the project-local `mac-assed-mac-app` skill (`.claude/skills/`): full menu-bar
command coverage, keyboard-first operation, standard Settings scene, drag/copy affordances,
VoiceOver. The review stream deliberately has no text input — Claude speaks, the room talks out
loud.
