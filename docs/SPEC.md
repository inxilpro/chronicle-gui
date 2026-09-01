# Chronicle for Mac — port specification

Chronicle is a native macOS companion app for live technical planning calls. It sits between
three collaborators:

- **Tuple** — the pairing call. Chronicle consumes Tuple's CLI for call discovery and
  machine-readable transcription.
- **The Chronicle IDE plugin** (PhpStorm/IntelliJ) — publishes raw IDE activity to `~/.chronicle`
  per [`ide-wire-contract.md`](ide-wire-contract.md). The Mac app is a *consumer* of those files
  and never modifies them.
- **Claude Code** (or any LLM harness) — runs the installed `chronicle` skill, follows the call
  through the `chronicle` CLI, maintains a Markdown planning handoff, and speaks to the room
  through the app's review stream.

Chronicle owns the live session for the current Tuple call, gives Claude a visible review stream,
and renders the internal Markdown handoff as Claude edits it. It writes nothing into a project
until the user chooses **Save As…** for a finished handoff.

This is a native Swift port of the earlier Tauri prototype ("scribe",
`/Users/inxilpro/Development/tauri/scribe`). The product behavior below is the scribe contract
with these renames and deliberate changes:

| scribe | Chronicle |
| --- | --- |
| `scribe` CLI | `chronicle` CLI |
| `scribe tick` | `chronicle show` |
| `planning-scribe` skill at `~/.claude/skills/planning-scribe` | `chronicle` skill at `~/.claude/skills/chronicle` |
| `~/.scribe/scribe.db`, `~/.scribe/sessions/` | `~/Library/Application Support/Chronicle/chronicle.db`, `…/Chronicle/sessions/` |
| `~/.scribe/bin/scribe` shim | `~/.chronicle/bin/chronicle` shim |
| `SCRIBE_HOME` override | `CHRONICLE_APP_HOME` override |
| Tuple durable cursor `scribe-<call-id>` | `chronicle-<call-id>` |
| `source: "scribe"` synthetic events | `source: "chronicle"` synthetic events |
| PhpStorm hardcoded for file opens | Configurable editor (PhpStorm default) |
| `tick --wait` only waits on Tuple | `show --wait` also waits on local undelivered events |
| 500 ms full-snapshot polling GUI | FSEvents/GRDB observation where practical |

Naming note: "Chronicle" now names the whole product family — the IDE plugin, this Mac app, and
its CLI. In code, `ChronicleIDE`/`ide` prefixes refer to the plugin's published data; unprefixed
types are the Mac app's own domain.

## 1. Architecture

One Xcode project, three build products:

- **Chronicle.app** — SwiftUI app (macOS 26.5+, not sandboxed, hardened runtime). Depends on
  `ChronicleKit` and Sparkle.
- **chronicle** — command-line tool target embedded at `Chronicle.app/Contents/Helpers/chronicle`
  (`Contents/MacOS` would collide with the app binary on a case-insensitive filesystem).
  Thin `main.swift` over `ChronicleCLICore`.
- **ChronicleKit** — local Swift package at `ChronicleKit/` holding all logic:
  - `ChronicleKit` library: models, paths, SQLite store (GRDB), Tuple client, IDE-plugin
    ingestion, collector, git helpers, skill installer, handoff markdown model.
  - `ChronicleCLICore` library: swift-argument-parser command tree (kept as a library so tests
    can drive commands).

Package deps: GRDB.swift, swift-argument-parser, apple/swift-markdown. App-only dep: Sparkle 2.

**No daemon, no sockets.** The GUI and CLI are separate processes coordinating through the
SQLite database (WAL, busy timeout ≥ 10 s, immediate transactions) and advisory file locks at
`<app home>/locks/<source>-<first-16-hex-of-sha256(session-id)>.lock`. CLI writes never require
the GUI to be running.

### Storage layout

```text
~/Library/Application Support/Chronicle/     ("app home"; CHRONICLE_APP_HOME overrides, for tests/dev)
  chronicle.db
  locks/
  sessions/<safe-session-id>/notes.md        the internal handoff; Claude edits it, the app renders it
~/.chronicle/bin/chronicle                   stable symlink to the embedded CLI (skill uses the absolute path)
~/.claude/skills/chronicle/SKILL.md          installed skill (template resource, {{CHRONICLE_BIN}} substituted)
```

`<safe-session-id>` = the Tuple call id when it matches `[A-Za-z0-9_-]+`, else
`call-<first 16 hex of sha256(id)>`.

The IDE plugin root (read-only to us) resolves in order: explicit folder chosen in the app
(persisted in `settings`), `CHRONICLE_HOME` from the environment, `~/.chronicle`.

### Timestamps

Always UTC RFC 3339 with exactly three fractional digits: `2026-09-01T12:00:00.000Z`. One shared
formatter in ChronicleKit; every stored/emitted timestamp goes through it.

## 2. Domain model

All Codable structs encode camelCase. Optional fields are omitted when nil (never `null`).

```swift
enum SessionState: String { case active, finalizing, complete, interrupted }
enum AppMode: String { case waitingCall, waitingTranscription, waitingClaude,
                            active, finalizing, complete, interrupted }
enum MessageKind: String { case message, ack, decision }
enum DecisionStatus: String { case unreviewed, approved, rejected }

struct DocumentReference { var heading: [String]; var snippet: String }
struct FileReference { var path: String; var line: Int?; var endLine: Int?; var sha: String }

struct ChatMessage {
  var id: String; var kind: MessageKind; var timestamp: String; var text: String
  var reference: DocumentReference?; var files: [FileReference]
  var read: Bool; var decisionStatus: DecisionStatus?
}

struct SourceHealth { var source: String; var status: String; var label: String; var detail: String? }
// sources are exactly, in order: "tuple", "claude", "chronicle" (the IDE plugin)
// status → label: live→Live, connected→Connected, waiting→Waiting, stopped→Stopped,
//                 ended→Ended, ambiguous→"Choose source", error→"Needs attention", off→Off

struct SessionSummary { var id, state, startedAt, updatedAt: String
                        var attachedRepo: String?; var hasUnsavedHandoff: Bool; var dataPruned: Bool }

struct IDESessionCandidate {           // an entry from the plugin's sessions.json
  var id, state, logPath, projectName, projectRoot: String
  var repositories: [IDERepository]   // { root: String, branch: String? }
  var startedAt, lastEventAt: String; var endedAt: String?
}

struct NormalizedEvent {
  var stableId: String; var source: String        // "tuple" | "chronicle-ide" stored as "chronicle"? see §5
  var streamId: String?; var sourceSequence: Int64?
  var occurredAt, observedAt: String
  var kind: String; var payload: JSONValue
}

struct ShowResult {                                 // `chronicle show` output; scribe's TickResult
  var sessionId: String; var sessionState: SessionState
  var notesPath: String; var repoPath: String?
  var sourceHealth: [SourceHealth]
  var events: [NormalizedEvent]; var hasMore: Bool
}

struct SessionInfo {                                // `session attach` / `session current` output
  var sessionId: String; var state: SessionState
  var notesPath: String; var repoPath: String?
  var sourceHealth: [SourceHealth]
}

struct AppSnapshot {                                // what the GUI renders
  var mode: AppMode; var sessionId: String?; var sessionState: SessionState?
  var notesPath: String?; var repoPath: String?
  var markdown: String; var messages: [ChatMessage]; var sources: [SourceHealth]
  var sessions: [SessionSummary]; var ideCandidates: [IDESessionCandidate]
  var ideRoot: String; var ideRegistryFound: Bool
  var integrationInstalled: Bool; var handoffSaved: Bool
}
```

**Event source naming:** normalized events use `source` values `tuple`, `chronicle` (synthetic
review events from this app — scribe called these `scribe`), and `ide` (events imported from the
IDE plugin — scribe called these `chronicle`). The `SourceHealth.source` values shown to skill
and UI are `tuple`, `claude`, `chronicle` where `chronicle` means the IDE plugin. The skill
documents these names; keep them exact.

There are no separate note/task entities. "Notes" is one Markdown file per session owned by
Claude. A decision = a `decision` chat message + a `decision_reviews` row + an invisible
`<!-- chronicle-decision: id -->` marker in the Markdown. Review actions flow back to Claude as
synthetic events (§6).

## 3. Database

GRDB, WAL, `user_version`-style migrations (use GRDB's migrator). Single schema v1 equal to
scribe's final (post-migration-3) schema:

```sql
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,                      -- the Tuple call ID
    state TEXT NOT NULL CHECK (state IN ('active','finalizing','complete','interrupted')),
    started_at TEXT NOT NULL, call_ended_at TEXT, finished_at TEXT, updated_at TEXT NOT NULL,
    repo_path TEXT, notes_path TEXT NOT NULL UNIQUE,
    saved_hash TEXT, saved_at TEXT, saved_destination TEXT,
    data_pruned INTEGER NOT NULL DEFAULT 0 CHECK (data_pruned IN (0,1))
);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE source_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    stable_id TEXT NOT NULL, source TEXT NOT NULL,
    stream_id TEXT, source_sequence INTEGER,
    occurred_at TEXT NOT NULL, observed_at TEXT NOT NULL,
    kind TEXT NOT NULL, payload_json TEXT NOT NULL,
    UNIQUE (session_id, source, stable_id)
);
CREATE INDEX source_events_consumer_order ON source_events(session_id, sequence);
CREATE INDEX source_events_chronology ON source_events(session_id, occurred_at, sequence);
CREATE UNIQUE INDEX source_events_stream ON source_events(session_id, source, stream_id, source_sequence)
    WHERE stream_id IS NOT NULL AND source_sequence IS NOT NULL;
CREATE TABLE source_state (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    source TEXT NOT NULL, status TEXT NOT NULL, detail TEXT,
    cursor_json TEXT, updated_at TEXT NOT NULL, PRIMARY KEY (session_id, source)
);
CREATE TABLE chat_messages (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('message','ack','decision')),
    timestamp TEXT NOT NULL, text TEXT NOT NULL, reference_json TEXT,
    read INTEGER NOT NULL CHECK (read IN (0,1)),
    decision_status TEXT CHECK (decision_status IN ('unreviewed','approved','rejected')),
    UNIQUE (session_id, id)
);
CREATE TABLE file_references (
    session_id TEXT NOT NULL, message_id TEXT NOT NULL, position INTEGER NOT NULL,
    path TEXT NOT NULL, line INTEGER, end_line INTEGER, sha TEXT NOT NULL,
    PRIMARY KEY (session_id, message_id, position),
    FOREIGN KEY (session_id, message_id) REFERENCES chat_messages(session_id, id) ON DELETE CASCADE
);
CREATE TABLE decision_reviews (
    session_id TEXT NOT NULL, decision_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('approved','rejected')),
    reviewed_at TEXT NOT NULL,
    PRIMARY KEY (session_id, decision_id),
    FOREIGN KEY (session_id, decision_id) REFERENCES chat_messages(session_id, id) ON DELETE CASCADE
);
CREATE TABLE consumer_cursors (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    consumer TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL, PRIMARY KEY (session_id, consumer)
);
CREATE TABLE consumer_deliveries (
    session_id TEXT NOT NULL, consumer TEXT NOT NULL,
    event_sequence INTEGER NOT NULL REFERENCES source_events(sequence) ON DELETE CASCADE,
    delivered_at TEXT NOT NULL,
    PRIMARY KEY (session_id, consumer, event_sequence),
    FOREIGN KEY (session_id, consumer) REFERENCES consumer_cursors(session_id, consumer) ON DELETE CASCADE
);
CREATE TABLE ide_candidates (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    id TEXT NOT NULL, candidate_json TEXT NOT NULL,
    selected INTEGER NOT NULL DEFAULT 0 CHECK (selected IN (0,1)),
    PRIMARY KEY (session_id, id)
);
```

Known `settings` keys: `ide_root` (explicit IDE-plugin folder), `tuple_discovery_error`,
`selected_session`.

### Store behaviors (mirror scribe exactly unless noted)

- **`createOrResumeSession(callId)`** — creates `sessions/<safe-id>/notes.md` (empty), demotes
  any *other* `active` session to `interrupted`, upserts the row (an `interrupted` row for this
  id returns to `active`), seeds `source_state('tuple','waiting')`, sets `selected_session`.
- **`markCallEnded`** → `finalizing` + `call_ended_at`. **`finishSession`** → `complete` only
  from `finalizing`; errors otherwise with the state-specific messages in §4.
- **`interruptStaleSessions(olderThan: 12h)`** at app launch demotes stale `active` rows.
  Improvement over scribe: also run it periodically from the GUI collector, not only at launch.
- **Selected session** — prefer any `active`/`finalizing` (active first, then `updated_at`
  DESC), else the `settings.selected_session` row. At GUI launch, clear a *terminal* selection so
  relaunch shows the waiting screen.
- **Mode derivation**: no selected session → `waitingCall`; active + tuple status `waiting` →
  `waitingTranscription`; active + repo nil → `waitingClaude`; active → `active`; otherwise the
  session state.
- **`show(sessionId, consumer, limit)`** (scribe's `tick`) — one IMMEDIATE transaction:
  upsert cursor row; select undelivered events (`LEFT JOIN consumer_deliveries … WHERE
  delivery IS NULL ORDER BY occurred_at, sequence LIMIT ?` — occurrence order, not insertion
  order); insert a delivery row per event (exactly-once, late-arriving events included);
  `hasMore` = any undelivered remain; advance `consumer_cursors.sequence` to max. Limit
  1…10 000. Concurrent shows for one consumer split events, never duplicate.
- **Retention (`prune`)** — terminal sessions ordered by `COALESCE(finished_at, updated_at)`
  DESC; newest five untouched. Older: if notes non-empty and `sha256(notes) != saved_hash`
  (unsaved), delete only operational rows and set `data_pruned = 1` (handoff file survives,
  History shows "Details expired"); if saved, delete the row and remove the session directory
  (refuse any path not under the app home's `sessions/`). Active/finalizing always retained.
  Once pruned, `show` returns empty forever.
- **Export** — allowed only in `complete`/`interrupted`; destination absolute and outside the
  app home; write temp sibling then rename; store `saved_hash`/`saved_at`/`saved_destination`.
  `handoffSaved` = notes non-empty AND current hash matches. Claude re-editing a saved handoff
  makes it unsaved again.
- All GUI mutations serialize behind one write path; CLI writes take the same store API.

## 4. CLI contract

`chronicle` — embedded in the app bundle; the skill invokes the absolute shim path
`~/.chronicle/bin/chronicle`. Exit 0 + result JSON/text on stdout; exit 1 + `chronicle: <message>`
on stderr. Built with swift-argument-parser; `--help` everywhere.

```text
chronicle session attach --repo <path>
chronicle session current --json
chronicle session finish
chronicle show [--wait] --cursor <name> [--timeout <duration>] [--limit <count>]
chronicle say <text> [--ref-heading <A>B>] [--ref-snippet <text>] [--file <path[:line[-end]]>]...
chronicle ack <text> [--file <path[:line[-end]]>]...
chronicle decision <text> --id <id> [--ref-heading <A>B>] [--ref-snippet <text>] [--file <path[:line[-end]]>]...
chronicle unlink <message-id>
chronicle read [<message-id>]
```

- **`session attach --repo <path>`** — resolve current session (creating/resuming from
  `tuple call current` if needed); `git -C <path> rev-parse --show-toplevel` + canonicalize;
  store `repo_path`; set `claude` source `connected` ("chronicle skill attached"); run IDE-plugin
  discovery. Prints `SessionInfo` JSON. Errors: `"<path> is not inside a Git repository"`, etc.
- **`session current --json`** — same shape; never creates a session; error
  `"no active or finalizing Chronicle session; join a Tuple call first"`. The literal `--json`
  flag is required (contract stability for the skill).
- **`session finish`** — drain sources once (1 ms timeout), then `complete` only from
  `finalizing`. Errors: `"Tuple call is still active; finish after Chronicle reports finalizing"`,
  `"session is already complete"`, `"an interrupted session cannot be finished"`.
  Prints `{"sessionId":"…","state":"complete"}`.
- **`show`** — `--cursor` required (non-empty, no whitespace); `--timeout` grammar
  `<digits>(ms|s|m)`, 1 ms…5 m, default `30s`; `--limit` default 200, 1…10 000. Without
  `--wait`, collect with 1 ms Tuple timeout and return immediately. With `--wait`: loop —
  collect (Tuple timeout ≤ ~2 s per pass), check for undelivered events; return as soon as any
  exist or the deadline passes (improvement over scribe: waits on local data, not only Tuple's
  long-poll). Prints `ShowResult` JSON; `hasMore: true` means call again immediately.
- **`say` / `ack` / `decision`** — bind to the active/finalizing session; print
  `posted <command> <message-id>`. Text is the first positional, non-empty after trim, must not
  start with `--`. `--ref-heading` splits on `>` (parts trimmed); requires `--ref-snippet` and
  vice versa; neither empty. `ack` may not carry a reference. `decision` requires `--id`
  (no whitespace, unique in session — duplicate errors `message ID already exists: <id>`); the
  message id *is* the `--id` value. `say`/`ack` ids are UUIDv4. Posting requires an attached
  repo (`"the chronicle skill has not attached a repository"`). `--file` specs plus any
  backticked token in the text containing `/` and no whitespace are parsed
  (`path[:line[-endLine]]`), deduped in order; all get the full current `git rev-parse HEAD`.
- **`unlink <message-id>`** — nulls the reference. `unlinked <id>`; errors
  `message not found: <id>`, `message has no document reference: <id>`.
- **`read [<message-id>]`** — mark that message read, or all non-`ack` messages.
  `marked <id> read` / `marked all messages read`.

## 5. Sources and the collector

`collectOnce(store, tupleTimeout)` — the shared collection pass (GUI collector loop, and every
CLI `show`/`session` command):

1. `tuple call current --format json` (accept `id`/`call_id`/`callId`). Output containing
   "not in a call" → no call, not an error. If it differs from the stored session, create/resume.
   If Tuple reports no call but a local `active` session exists, still collect (that's how the
   explicit `call_ended` record arrives). Lookup errors with no session → persist
   `tuple_discovery_error` for the waiting screen.
2. Tuple transcription, under an exclusive lock on `locks/tuple-<hash>.lock`:
   `tuple --format json transcription show <call-id> --wait --timeout <t> --with-events --cursor chronicle-<call-id>`.
   Tuple owns that durable cursor (backlog catch-up and restart-without-gaps are Tuple's job).
3. IDE-plugin discovery + collection (registry match, JSONL tail, import).

Tuple binary discovery: `$TUPLE_BIN`, `/usr/local/bin/tuple`, `/opt/homebrew/bin/tuple`, then
`tuple` on PATH.

**Tuple record normalization** (port scribe's rules exactly):

- `"kind":"status"` lines: only `"status":"call_ended"` matters → synthetic event
  `stableId "tuple:call-ended"`, `kind "call_ended"`, and `markCallEnded` (→ `finalizing`).
- Drop `user_audio_started`/`user_audio_stopped` and empty/whitespace speech.
- `transcription_finished` → `kind "speech"`, `occurredAt` from `data.start` (spoken start,
  falling back to `time`); other kinds use `time`. Accept RFC 3339, numeric strings, epoch
  seconds or millis (`< 1e11` ⇒ seconds).
- `stableId` = `tuple:<type>:<id>` (record `id` or `data.id` — string, number, or nested
  `{id}`), else `tuple:<sha256 of raw line>`.
- Speech payload: `{"text":…, "speakerId": data.user_id, "raw": <original record>}`; other
  kinds keep the raw record.
- Health: `transcription_finished|transcription_started|recording_started` → `live`
  "Transcription is live."; `transcription_dropped` → `stopped` "Tuple reported a transcription
  gap. Chronicle will not restart it automatically."; `recording_ended|transcription_ended` →
  `stopped` "Transcription stopped during the call. Restart it in Tuple if intended.".
- Malformed lines counted, not fatal → `error` "Ignored N malformed Tuple record(s); durable
  records were kept."
- Non-zero tuple exits: distinguish "transcription is not running / no recording / capture not
  running / not transcribing" (→ `waiting` before transcription ever started, `stopped` after
  live) from real failures. Map diagnostics to actionable guidance: missing Microphone /
  Screen & System Audio Recording / Accessibility permission; socket connection refused → "Open
  the Tuple app"; auth denied → "Tuple Settings → Integrations → CLI Server"; not signed in;
  transcription store unavailable → "Start Capture once in Tuple". Always append the exact
  command and Tuple's diagnostic.

**IDE-plugin ingestion** (source `chronicle` in health, events stored with source `ide`):

- Read `sessions.json` per the wire contract; validate schemaVersion 1, unique non-empty ids,
  `state ∈ {active, completed, interrupted}`, absolute `logPath`/`projectRoot`/roots,
  timestamps exactly `YYYY-MM-DDTHH:MM:SS.mmmZ`, active ⇒ no `endedAt`, `pid != 0`. Ignore
  `sessions.json.lock`. Tolerate unknown *registry* fields (deliberate loosening vs scribe: the
  plugin is ours and will evolve; unknown keys in the registry must not fail-close).
- **Matching** after the skill attaches a repo: candidates whose any `repositories[].root`
  canonicalizes equal to the attached Git root; if any `active`, keep only active; if any
  time-overlaps the session window, keep only overlapping; sort `startedAt` DESC. Exactly one →
  auto-select (health from its state: active→`live` "Chronicle detected", completed→`ended`,
  interrupted→`stopped`). Zero → `off` "Not detected". Several → `ambiguous` "Multiple Chronicle
  sessions match this repository." and the UI offers the picker.
- **Log tailing**: cursor `{path, offset, fileId (inode), lastSequence, lastType}` persisted in
  `source_state.cursor_json`; reset when path changed, file shrank, or inode changed. Read from
  offset; consume only complete newline-terminated lines (defer a partial tail); strip `\r`.
- **Envelope validation**: schemaVersion 1; non-empty id; `sessionId` matches; `sequence`
  strictly `last + 1`; sequence 1 ⇔ `session_started`; nothing after `session_ended`;
  `redacted` present only as `true`; millisecond-UTC timestamps; no duplicate ids in a chunk;
  empty lines are an error. Event `data` validated per the wire-contract table (required keys
  present, path rules, `startLine ≤ endLine`); `audio_transcription` always rejected. Unknown
  *event types* and unknown `data` keys → error (fail-closed on the log itself, matching
  scribe; the log is the contract). Registry `completed` but log not ending in `session_ended`
  → error. Any failure sets health `error` with the message and preserves the previous cursor.
- **Normalized form**: `stableId` = envelope id, `source` "ide", `streamId` = IDE session id,
  `sourceSequence` = sequence, `kind` = type, payload
  `{"recordedAt":…, "data":…, "redacted":true?, "contentTrust":"trusted"|"untrusted; read the referenced file"}`.
  Merged into the timeline by `occurredAt`, never append order.
- Never delete or modify anything under the IDE root.

**Synthetic review events** (source `chronicle`), injected so the skill sees them in its next
`show`:

```json
{"stableId":"decision-review:<id>","source":"chronicle","kind":"decision_approved"|"decision_rejected",
 "payload":{"decisionId":"<id>","status":"approved"|"rejected"}}
{"stableId":"reference-stale:<messageId>","source":"chronicle","kind":"reference_stale",
 "payload":{"messageId":"…","locator":{"heading":[…],"snippet":"…"}}}
```

`reviewDecision` is idempotent for a repeat of the same status; a different status errors
("decision has already been reviewed"). Stale-reference reports come from the renderer when a
`DocumentReference` no longer resolves; verify the stored locator still matches before inserting,
dedupe.

**The `claude` source** has no reader: `connected` when `repo_path` is set, else `waiting`
"Waiting for the chronicle skill to attach from a repository".

## 6. Skill and integration install

App action **Install Claude integration** (also surfaced on first run):

1. Symlink the embedded CLI to `~/.chronicle/bin/chronicle` atomically (temp name + rename).
2. If `~/.claude/skills/chronicle/SKILL.md` exists without the marker
   `<!-- installed-by-chronicle -->`, back it up beside itself as
   `SKILL.md.before-chronicle-<uuid>`.
3. Write the bundled template with `{{CHRONICLE_BIN}}` replaced by the shim's absolute path,
   atomically.
4. `integrationInstalled` = shim exists AND skill file exists.

The skill template lives in the repo at `Resources/skill/SKILL.md` (bundled into the app). Its
content is ported from scribe's `planning-scribe` skill with the renames of §0: attach → follow
the call in a `show --wait --cursor chronicle --timeout 30s --limit 200` loop → maintain the
handoff (decision markers `<!-- chronicle-decision: id -->`, `**Status:**` lines, file refs
`` `path:line` @sha `` ) → speak sparingly through `say`/`ack`/`decision` → on `call_ended`
drain, restructure, `session finish`. The handoff document template and the chat/body/nowhere
discipline table carry over verbatim in spirit.

## 7. The app (Mac-assed requirements)

Shoebox-style single main window ("Chronicle"), not document-based (the handoff is internal
until exported), plus auxiliary windows. Follow the `mac-assed-mac-app` skill throughout.

- **Main window**: two panes in a real split (persisted widths): left the **Review** stream
  (Claude's chat: message bubbles, quiet ack rows, decision cards with Approve/Reject), right
  the **Planning handoff** rendered Markdown. Toolbar: source status (three dots with
  popover detail), unread count, Mark All as Read, History. Waiting states render centered
  guidance (waiting for call / transcription / skill attach) with an Install-integration call
  to action when needed.
- **Decision cards** are the confirmation surface: Approve / Reject buttons, optimistic,
  becoming a static reviewed state. Also post macOS **UserNotifications** for new decisions
  (actions: Approve/Reject) and optionally messages; clicking focuses the card.
- **Markdown pane**: parse with swift-markdown; render natively (SwiftUI/AttributedString).
  Strip HTML comments (that's how decision markers stay invisible). Inline code spans followed
  by `@<4-64 hex>` render as file-reference buttons (SHA hidden, shown on hover via help tag)
  that open the file in the configured editor at the line. Document-reference chips in chat
  scroll-and-highlight the exact snippet; unresolvable ones render stale and report back.
  Preserve scroll position across live edits (anchor to nearest heading). Text is selectable;
  ⌘F find bar; Plan-ready state offers Copy (⌥ copies as rendered rich text) and Save As….
- **Menus**: full command model. File: Save Handoff As… (⇧⌘S), Copy Handoff, Close. Session:
  Mark All as Read (⇧⌘U), Delete Session…. View: toggle panes, text size. Window/Help standard.
  History window (⌥⌘H) listing recent sessions (state chip, unsaved-handoff badge, "Details
  expired", delete with confirmation). Settings (⌘,): General (editor choice: PhpStorm,
  IntelliJ IDEA, VS Code, Cursor, custom URL template; IDE-plugin folder override with
  Choose…), Integration (install/reinstall, shim + skill paths, optional `/usr/local/bin`
  symlink), Updates (Sparkle: check automatically, check now, channel).
- **Dock badge**: unread count of `message` + `decision` messages.
- **Liveness**: GRDB ValueObservation for DB-driven UI updates; DispatchSource/FSEvents watch
  on `notes.md`; background collector loop (~2 s Tuple wait) on a task, not a 500 ms poll.
  Copy for empty/waiting states matches scribe's strings (§UI strings in scribe report) unless
  improved deliberately.
- **State restoration**: window frames, pane widths, selected session survive relaunch (but a
  terminal session clears to the waiting screen, per §3).
- Keyboard, VoiceOver, light/dark, and copy/drag affordances per the skill's checklist: chat
  messages and handoff text copyable; handoff draggable as a `.md` file promise from the
  Plan-ready header; file references copyable as `path:line`.

## 8. Updates and releases

- **Sparkle 2** via SPM. `SUFeedURL` points at the GitHub Releases-hosted appcast
  (`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`); `SUPublicEDKey`
  placeholder committed, real key injected/set before first release. Standard updater UI, check
  automatically by default; "Check for Updates…" in the app menu.
- **CI** (`.github/workflows/ci.yml`): on PR/push — `swift test` for ChronicleKit +
  `xcodebuild build` (unsigned) for the app; macOS 26 runner.
- **Release** (`.github/workflows/release.yml`): on tag `v*` — build Release, codesign with
  Developer ID (secrets: cert P12 + password, team id), notarize (`notarytool`, App Store
  Connect API key secrets), staple, produce DMG + zip, generate/sign appcast with Sparkle's
  `generate_appcast` (ed key secret), upload to the GitHub Release. Document required secrets
  in `docs/RELEASING.md`.

## 9. Out of scope (deliberate)

- No text input for the room to chat with Claude (the room speaks; Chronicle chat is Claude's
  voice only — matches the skill's design).
- No transcript/chat export beyond the handoff Save As….
- No App Store build, no sandbox.
- Handoff mode of the IDE plugin (never touches `~/.chronicle`).
