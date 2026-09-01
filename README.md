# Chronicle

Chronicle is a native Mac companion for live technical planning calls. It sits
between three collaborators:

- **Tuple** — the pairing call. Chronicle consumes Tuple's CLI for call
  discovery and machine-readable transcription.
- **The Chronicle IDE plugin** (PhpStorm/IntelliJ) — publishes raw IDE activity
  to `~/.chronicle`. The app reads those files and never modifies them.
- **Claude Code** — runs the installed `chronicle` skill, follows the call
  through the `chronicle` CLI, and maintains a Markdown planning handoff.

The app owns the live session for the current Tuple call, shows Claude's
review stream (facts, contradictions, and decision cards the room can approve
or reject), and renders the internal Markdown handoff as Claude edits it. It
writes nothing into a project until the user chooses **Save As…** for a
finished handoff.

## Installed-app workflow

1. Install Chronicle in Applications and open it. With no call, it waits and
   detects the next Tuple call without a restart.
2. Start transcription in Tuple when wanted. Chronicle never starts or
   restarts transcription; if transcription stops during a call, Chronicle
   reports the gap.
3. On first use, choose **Install Claude integration**. This installs the
   `chronicle` skill and a stable CLI shim at `~/.chronicle/bin/chronicle`; no
   shell `PATH` edits are needed. A pre-existing user-managed `chronicle` skill
   is backed up beside `SKILL.md` before the managed version is installed.
4. Start the `chronicle` skill from Claude in the Git repository being planned.
   The skill attaches that repository to the active call and learns Chronicle's
   internal notes path.
5. After Tuple reports that the call ended, Claude performs its final notes
   pass and finishes the session. Chronicle presents **Plan ready** with
   **Copy** and native **Save As…** actions. Save As copies the internal
   handoff; it does not move it.

The Tuple call ID is the Chronicle session ID. History is for opening recent
sessions and recovering unsaved handoffs.

Tuple's CLI must be installed from Tuple Settings → Integrations → CLI Server.
Chronicle checks `$TUPLE_BIN`, `/usr/local/bin/tuple`, `/opt/homebrew/bin/tuple`,
and then `PATH`.

## CLI contract

The app embeds a `chronicle` CLI at `Contents/Helpers/chronicle`; the installed
skill invokes it through the `~/.chronicle/bin/chronicle` shim. Successful
commands print JSON or text on stdout; failures exit 1 with a readable
`chronicle: <message>` on stderr.

```text
chronicle session attach --repo <path>     attach a Git repo to the current call; prints session info JSON
chronicle session current --json           current session info; never creates a session
chronicle session finish                   complete a finalizing session (after call_ended)
chronicle show [--wait] --cursor <name> [--timeout <duration>] [--limit <count>]
                                           collect sources and deliver the next durable event batch
chronicle say <text> [--ref-heading <A>B>] [--ref-snippet <text>] [--file <path[:line[-end]]>]...
chronicle ack <text> [--file ...]          quiet acknowledgement (no reference allowed)
chronicle decision <text> --id <id> [...]  post a decision card for room review
chronicle unlink <message-id>              remove a stale document reference
chronicle read [<message-id>]              mark a message (or all) read
```

`show` performs source collection, normalization, deduplication, chronological
ordering, and a transactional durable cursor per consumer — every event is
delivered exactly once, even across restarts. `hasMore: true` means call again
immediately. CLI writes never require the GUI to be running. Run
`chronicle --help` for full syntax.

## Storage and privacy

SQLite is the single operational source of truth:

```text
~/Library/Application Support/Chronicle/    ("app home"; CHRONICLE_APP_HOME overrides for tests/dev)
  chronicle.db
  locks/
  sessions/<session-id>/notes.md            the internal handoff Claude edits
~/.chronicle/bin/chronicle                  stable symlink to the embedded CLI
~/.claude/skills/chronicle/SKILL.md         installed skill
```

The IDE plugin's `~/.chronicle` data is read-only to the app: it is never
modified or deleted. There are no project chat, transcript, event, or notes
sidecars, and no raw-transcript export — a finished handoff via explicit
**Save As…** is the only way anything reaches a project.

Retention: the newest five complete/interrupted sessions keep full operational
and chat data; active and finalizing sessions are always retained. Older
terminal sessions have operational data pruned, but any handoff that was never
saved externally is protected and surfaced in History. A content hash tracks
the last Save As, so later edits make a handoff unsaved again.

## Development

Open `Chronicle.xcodeproj` in Xcode. Three build products: `Chronicle.app`
(SwiftUI), the `chronicle` CLI (embedded at `Contents/Helpers/chronicle`), and
the local `ChronicleKit` Swift package holding all logic.

Run the package tests:

```sh
cd ChronicleKit
swift test
```

CI (`.github/workflows/ci.yml`) runs the package tests and an unsigned app
build; releases are cut by tag (see below).

## Documentation

- [docs/SPEC.md](docs/SPEC.md) — the full product and architecture spec
- [docs/ide-wire-contract.md](docs/ide-wire-contract.md) — the IDE plugin's wire contract
- [docs/RELEASING.md](docs/RELEASING.md) — signing, notarization, Sparkle, and release steps
