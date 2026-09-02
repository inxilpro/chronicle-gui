# Chronicle session logs

Chronicle publishes IDE activity to a well-known location so another tool can discover and tail it.
Chronicle knows nothing about the consumer: it publishes a session, the consumer finds it.

This document is the wire contract. It is versioned with the code that produces it.

> Provenance: this is the authoritative wire contract for the Chronicle IDE plugin's data layer,
> copied into this repository so the consumer (the Chronicle Mac app) and producer (the IDE plugin)
> can evolve together. The IDE plugin is maintained by the same team.

## Modes

Chronicle records in one of two modes, chosen in the Chronicle tool window:

| Mode | Audio | Output |
| --- | --- | --- |
| **Handoff** | Recorded and transcribed | Nothing on disk until you export a prompt at the end of the session |
| **Scribe** | Off | IDE events streamed to `~/.chronicle` as they happen |

Only Scribe mode produces the files described here. Handoff mode never writes to `~/.chronicle`
and never registers a session.

## Storage layout

```text
~/.chronicle/
  sessions.json            registry of active and recently completed sessions
  sessions.json.lock       inter-process lock; ignore it
  sessions/
    <session-id>.jsonl     one append-only log per recording
```

The root is `~/.chronicle`, overridable with the `chronicle.home` system property or the
`CHRONICLE_HOME` environment variable, in that order.

## `sessions.json`

Rewritten atomically (temp file plus `ATOMIC_MOVE`) under an inter-process file lock, so a reader
always sees a complete document. Several IDE windows and several IDE processes publish into the
same file; each rewrites only its own entries.

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-09-01T12:00:00.000Z",
  "sessions": [
    {
      "id": "8aadfd6e-1c4a-4a3d-9f2b-6f1b2c3d4e5f",
      "state": "active",
      "logPath": "/Users/chris/.chronicle/sessions/8aadfd6e-1c4a-4a3d-9f2b-6f1b2c3d4e5f.jsonl",
      "projectName": "demo",
      "projectRoot": "/Users/chris/Code/demo",
      "repositories": [
        { "root": "/Users/chris/Code/demo", "branch": "main" }
      ],
      "startedAt": "2026-09-01T11:45:00.000Z",
      "lastEventAt": "2026-09-01T11:59:58.230Z",
      "heartbeatAt": "2026-09-01T11:59:45.000Z",
      "endedAt": null,
      "ide": { "product": "PhpStorm", "version": "2026.2" },
      "pid": 40123
    }
  ]
}
```

### States

| State | Meaning |
| --- | --- |
| `active` | The owning IDE is recording into this log right now |
| `completed` | Recording stopped cleanly; the log ends with `session_ended` |
| `interrupted` | The owning IDE went away without finalizing; the log holds whatever was flushed |

`heartbeatAt` advances every 30 seconds while a session is active. Any Chronicle process that
publishes will demote a foreign `active` entry to `interrupted` when its `pid` is gone or its
heartbeat is more than five minutes stale, so a consumer does not have to detect crashes itself.

### Matching a session

`repositories` lists **every** Git root in the IntelliJ project, not just the first, because one
project routinely spans several. Match on canonical repository root, then `active`, then
overlapping timestamps. Without the Git plugin the roots still appear, but `branch` is `null`.
If several sessions still match, ask rather than guess.

## Session logs

`sessions/<session-id>.jsonl` is UTF-8, append-only, one complete JSON object per line, flushed
after every line so it can be tailed. It is never rewritten and never reused: starting another
recording creates another id and another file, so file identity and session identity are the same
thing.

A consumer should expect the final line of a log to be truncated if the IDE was killed mid-flush.
Discard a line that does not parse; every earlier line is intact.

### Envelope

Every line, lifecycle records included, has the same shape:

```json
{
  "schemaVersion": 1,
  "id": "93cbd814-8f0e-4a1c-9b7d-2e5a1c9d3f77",
  "sessionId": "8aadfd6e-1c4a-4a3d-9f2b-6f1b2c3d4e5f",
  "sequence": 42,
  "type": "selection",
  "occurredAt": "2026-09-01T11:52:14.120Z",
  "recordedAt": "2026-09-01T11:52:14.390Z",
  "data": { "path": "src/App.kt", "startLine": 40, "endLine": 45, "text": "…" }
}
```

| Field | Notes |
| --- | --- |
| `id` | Globally unique; use it to deduplicate across re-reads |
| `sequence` | Monotonic append order within the session, starting at 1, no gaps |
| `occurredAt` | When the IDE action happened |
| `recordedAt` | When Chronicle persisted it |
| `redacted` | Present and `true` only when redaction changed the event; absent otherwise |
| `data` | Event-specific fields; null fields are omitted rather than written as `null` |

Timestamps are always UTC with exactly three fractional digits.

`occurredAt` and `recordedAt` differ meaningfully: shell commands are backfilled by polling shell
history, so a record with an older `occurredAt` can appear after newer ones. Sort by `occurredAt`
for a timeline and by `sequence` for append order — never assume they agree.

### Lifecycle records

`session_started` is always `sequence: 1`.

```json
{"type": "session_started", "data": {
  "projectName": "demo",
  "projectRoot": "/Users/chris/Code/demo",
  "repositories": [{"root": "/Users/chris/Code/demo", "branch": "main"}],
  "ide": {"product": "PhpStorm", "version": "2026.2"},
  "pid": 40123
}}
```

`session_ended` is always the last line. Its own `sequence` is the log's total record count, which
is how you tell a complete log from a truncated one. `reason` is `stopped` (the user pressed Stop),
`shutdown` (project closed or IDE exited), `restarted` (a new recording replaced this one), or
`error` (a write failed).

```json
{"type": "session_ended", "data": {"reason": "stopped", "state": "completed"}}
```

### Event types

| `type` | `data` |
| --- | --- |
| `file_opened`, `file_closed`, `file_created`, `file_deleted` | `path` |
| `file_selected` | `path`, `previousPath?` |
| `file_renamed`, `file_moved` | `oldPath`, `newPath` |
| `selection` | `path`, `startLine`, `endLine`, `text?` |
| `visible_area` | `path`, `startLine`, `endLine` |
| `document_changed` | `path`, `lineCount` |
| `branch_changed` | `repository` (absolute repo root), `branch?`, `state` |
| `search` | `query` |
| `refactoring` | `refactoringType`, `details` |
| `refactoring_undo` | `refactoringType` |
| `shell_command` | `command`, `shell`, `workingDirectory?` |
| `audio_transcription` | `transcriptionText`, `confidence?` — never emitted in Scribe mode |

Chronicle emits raw IDE activity and does no interpretation. Debouncing noisy scroll events,
folding checkout churn, computing dwell time, correlating selections with speech, and deciding
which events matter are all the consumer's job.

### Paths

File paths in `data` are relative to `projectRoot` when the file is inside the project, and
absolute otherwise. Repository roots — in `sessions.json`, in `session_started`, and in
`branch_changed.repository` — are always absolute. Resolve an event path against `projectRoot`,
then against the repository roots, to attribute it to a repository.

### Redaction

Chronicle redacts credentials and sensitive values before writing. When redaction changes an
event the envelope carries `"redacted": true`. Treat the snippet in a flagged event as untrusted
and read the referenced file instead — `path` and the line range are always accurate.

Redaction never corrupts scope resolution: `static::disk()` and `Str::beforeLast()` survive intact.
The IP address and URL filters, which match loosely enough to trip on ordinary source, are off by
default.

## Ownership and retention

Chronicle owns these files. A consumer must never delete them.

Chronicle keeps every `active` session plus the five most recently ended ones, pruning on each
session start and deleting the pruned logs. That is enough for a consumer to recover after a
restart. Import what you need into your own storage and apply your own retention there.
