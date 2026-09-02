# Chronicle UI design (mac-assed)

Companion to [SPEC.md](SPEC.md) §7. This is the design contract for the SwiftUI app.

## 1. Mac identity statement

- **Category**: developer utility / shoebox. There is one live session at a time (the Tuple
  call), a library of recent sessions, and one internal document per session that only becomes a
  file when the user exports it. Not document-based: no NSDocument, no open-with, no dirty dots
  — the handoff belongs to the app until Save As….
- **Primary workflows**: (1) glance while pairing — is transcription live, has Claude said
  anything, does a decision need review; (2) review decisions with one click or from a
  notification; (3) read the growing handoff without losing your place; (4) export the finished
  plan and paste/drag it wherever it goes next.
- **Conventions embraced**: real menu bar with full command coverage, keyboard-first review,
  standard Settings scene, Sparkle in the app menu, dock badge for unread, native save panel,
  services-grade copy behavior (plain + rich), window restoration, VoiceOver.
- **Deliberate departures**: the review stream has no text input (Claude speaks, the room
  talks out loud — the design is asymmetric on purpose); a single main window (the session *is*
  the call; multiple simultaneous sessions don't exist).

## 2. Windows

| Window | Scene | Notes |
| --- | --- | --- |
| **Chronicle** (main) | `Window` (single) | Split: Review stream (left, 320–560 pt, persisted) + Planning handoff (right). Waiting states replace content with centered guidance. Min 800×600, default 1200×800. Full restoration. |
| **History** | `Window`, ⌘Y | Recent sessions list. Selecting a terminal session loads it in the main window. Delete with confirmation. Not a popover — it's a real window a user may keep open. |
| **Settings** | `Settings` scene, ⌘, | Tabs: General, Integration, Updates. |
| **About** | standard | Standard about panel with a one-line credits tagline. |

Sheets/dialogs: session delete confirmation (`.confirmationDialog`), Save As (NSSavePanel via
`fileExporter` or AppKit panel — must default name `planning-handoff.md`, allow .md only),
Chronicle-IDE folder chooser (NSOpenPanel, directories only).

## 3. Main window anatomy

### Waiting states (no session / pre-active)

Centered column: app icon, eyebrow "Tuple call companion", heading + copy per mode:

- `waitingCall`: **"Waiting for a Tuple call"**, or **"Tuple call detected"** when the
  collector reports an available call. Below the copy: the source strip, any Tuple discovery
  error, a prominent **Start Session** button (enabled only while a call is available —
  sessions start explicitly, never merely because the app was open during a call), and (when
  integration is not installed) an **Install Claude Integration** button — or, when the
  installed skill no longer matches the bundled template, an **Update Claude Integration**
  button with a one-line explanation.
- If the IDE registry is missing: quiet note with a **Choose Chronicle Folder…** link.

### Review pane (left)

Header: "Review" + subtitle ("Agent stream" / "Session complete") + unread pill (cap 99+).

Banners (stacked, in priority order): integration missing (with inline Install) or skill
update available (with inline Update — the startup check compares the installed skill against
the bundled template), IDE-folder notice, dismissible error/live-warning, per-source detail for
`stopped|error|ambiguous`, and the mode banner with these strings:

- `waitingTranscription`: "Call found. Waiting for transcription — start transcription in Tuple."
- `waitingClaude`: "Waiting for the chronicle skill to attach from a repository."
- `finalizing`: "Tuple call ended. The agent is finishing the handoff." — with a
  **Finish Session…** accessory (confirmed), completing the session without waiting for an
  agent that may never finish.
- `interrupted`: "This session was interrupted. Review or save the handoff, then delete it when
  no longer needed."

IDE-session picker appears only when >1 candidate and status is `ambiguous`: rows of
`projectName · started time · state`.

Message feed: `List` (native scroll/keyboard behavior for free) of three row shapes sharing
one skeleton: a fixed-width SF Symbol status-icon gutter on the left, the content column
(a full-width bubble, except acks), and a timestamp gutter on the right — icon and timestamp
hang from the first text baseline, never vertically centered. Semantic colors throughout:
accent means "needs attention", tertiary gray means "settled".

- **ack** — quiet row, `info.circle` tertiary glyph, always read, **not selectable**. Keeps
  the shared gutters but has no bubble; its text aligns with the bubble edges.
- **message** — bubble: body (rendered inline markdown code/bold), optional reference chip.
  Read state lives entirely in the gutter dot: `circle.fill` accent while unread, tertiary
  gray once read — no "New" pill.
- **decision** — bubble whose title and gutter icon reflect review state: unreviewed →
  accent `questionmark.diamond.fill` + "Decision needs confirmation" + **Approve** /
  **Reject** footer; approved → tertiary `checkmark.diamond.fill` + "Decided" (gray, not
  green — green still reads as a call to action); rejected → tertiary `xmark.diamond.fill` +
  "Rejected" with secondary body text (gray, not red — a settled rejection is history, not
  an alert). Reviewed rows keep their bubble and body but drop the buttons. The bubble
  renders no inline reference link; the linked handoff section is reached through the
  context menu's **Jump to Section** (kept secondary deliberately — promote it only if
  usage shows it earns more prominence).

While the agent has signaled `chronicle working` and nothing new has landed, the feed's last
row is a **typing indicator**: a small bubble with three pulsing dots (iMessage-style; static
under Reduce Motion; AX label "Claude is working"). Not selectable; clears when the next feed
item arrives, the session finishes, or the signal expires (~2 min).

**Selection model:** decision cards and plain messages are selectable; acks are not. The
platform highlight is fully suppressed — `listRowBackground(.clear)` plus disabling the backing
NSTableView's `selectionHighlightStyle`, because the table otherwise flashes blue on click and
leaves a gray row background; selection draws an accent **outline** on the row's rounded rect
instead (click or keyboard). Selecting a row marks it read and emits a `message_selected` event
to the skill (so Claude knows which card the room is discussing). Selection never scrolls or
highlights the handoff pane — that is Jump to Section's job.

Reference chips (plain messages) show last heading segment + snippet; clicking — like Jump to
Section on a decision card — scrolls the handoff pane to the resolved range and flashes a
highlight. Unresolvable → chip/menu item hidden immediately + stale report back to the skill
(which unlinks it); a broken link is never rendered.

Context menu: Copy Message, Mark as Read, Approve/Reject Decision (unreviewed decisions),
Jump to Section + Copy Reference (rows with a live reference).

Empty state: "You're all caught up" / "New review notes and decisions will appear here."

Auto-scroll to bottom only when already within ~100 pt of the bottom.

Footer bar: source strip (three status dots: tuple / claude / chronicle — displayed as
Tuple / Agent / IDE, label + tooltip
detail, popover with full detail per source), Mark All as Read button with count.

### Handoff pane (right)

Header: "Planning handoff" + state label ("Live notes" · "Internal notes — notes.md" with path
tooltip, or **"Plan ready"** in `complete`/`interrupted` with "Saved ✓" pill when
`handoffSaved`, plus **Copy** and **Save As…** buttons). While a session can end
(`active`/`finalizing`), the header's top right carries a subtle small **End Session…** /
**Finish Session…** button (mirrors Session ▸ End Session… ⇧⌘E, confirmed) — ending must not
depend on the Tuple call ending, and must be discoverable without the menu bar. Never a big
red prominent button.

Body: rendered Markdown (native SwiftUI text, selectable). Requirements:

- HTML comments stripped (decision markers stay invisible).
- Inline code + ` @sha` renders as a file-reference button; help tooltip "Open file · commit
  abc1234"; click opens configured editor at path:line; context menu: Open in Editor, Copy Path,
  Copy Path with Line.
- Scroll position preserved across live re-renders (anchor to nearest heading + offset).
- Text size follows ⌘+/⌘−/⌘0 (View menu), persisted.
- ⌘F find bar (find + highlight within rendered notes; ⌘G next).
- Empty states per mode: "Waiting for transcription", "Waiting for the chronicle skill",
  "Finalizing the plan", or "No notes yet — the internal handoff will appear here as the
  chronicle skill writes it."

## 4. Affordance map

| Element | Control | Selection | Keyboard | Copy | Drag | Context menu | Saved state | AX |
|---|---|---|---|---|---|---|---|---|
| Review feed | `List` | single row (accent outline, no full-background highlight; acks unselectable; selecting marks read + emits `message_selected` + decisions jump the handoff pane) | ↑↓ move, Space toggles read, ⏎ approve / ⌫ reject focused decision | message text (plain) | — | Copy Message, Mark Read/Unread, Approve/Reject (decisions), Copy Reference | scroll pos (session-scoped) | list; decision rows announce state ("Decision needs confirmation, unread" / "Decided"/"Rejected") |
| Decision card buttons | `Button` | — | ⏎/⌫ when row focused | — | — | mirrored in row menu + Session menu | review status (db) | buttons labeled "Approve decision"/"Reject decision" |
| Reference chip | `Button` styled chip | — | activates on ⏎ | Copy Reference (heading › snippet) | — | Copy Reference | — | "Reference: <heading>" |
| Source strip | custom HStack of dots | — | focusable, ⏎ opens popover | — | — | — | — | each: "<source>, <status>" |
| Handoff view | selectable rendered text | native text selection | ⌘F/⌘G, ⌘+/−/0, PgUp/PgDn | selection as plain/rich | **drag `.md` file promise from header title** | Copy, Copy as Markdown, Open File Reference | scroll anchor, text size | heading outline exposed via rotor (AX headings) |
| File-ref button | `Button` inline | — | ⏎ | Copy Path / Path:Line | — | Open in Editor, Copy Path, Copy Path with Line | — | "path, line N, opens in editor" |
| History list | `Table` or `List` | single | ↑↓, ⏎ opens, ⌫ deletes (with confirm) | Copy call ID | drag unsaved handoff out as .md | Open, Save Handoff As…, Copy Call ID, Delete… | window frame, sort | rows: "repo name, state, date" |
| Waiting screen CTA | `Button` (prominent) | — | default button ⏎ | — | — | — | — | standard |

## 5. Command / menu plan

- **Chronicle**: About Chronicle · **Check for Updates…** (Sparkle) · Settings… ⌘, · standard.
- **File**: **Save Handoff As…** ⇧⌘S (enabled in complete/interrupted) · **Copy Handoff** ⌥⌘C
  (whole doc as markdown; always enabled when notes non-empty) · Close ⌘W.
- **Edit**: standard (Copy works on feed selection and handoff text selection) · **Find** ▸
  Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G (routes to handoff find bar).
- **Session**: **Mark All as Read** ⇧⌘U (disabled at 0 unread) · **Approve Decision** ⌘⏎ /
  **Reject Decision** ⌘⌫ (enabled when a decision row is focused & unreviewed) ·
  **Install Claude Integration…** (renames to Reinstall… when installed) · separator ·
  **End Session…** ⇧⌘E (active/finalizing; retitles to Finish Session… while finalizing) ·
  **Close Session** (terminal — back to the waiting screen, session stays in History) ·
  **Delete Session…** (terminal sessions only).
- **View**: Toggle Review Pane ⌥⌘1 · Actual Size ⌘0 / Zoom In ⌘+ / Zoom Out ⌘− (handoff text;
  validate at the scale limits) · standard toolbar/sidebar items if applicable.
- **Window**: standard + **History** ⌘Y (Safari's History shortcut; ⌥⌘H belongs to Hide Others).
- **Help**: Chronicle Help (opens README/docs), link to wire contract.

Command availability via focused-scene state; all items validate (disabled, never missing).

## 6. Notifications, badge, attention

- `UNUserNotificationCenter`: new **decision** → notification with Approve/Reject action
  buttons (category registered at launch; acting from the notification round-trips exactly like
  the in-app buttons). New plain **messages** → optional (Settings toggle, default on) single
  coalesced notification. Never notify for acks. Clicking a notification activates the app and
  scrolls the feed to that message.
- Dock badge: unread `message` + `decision` count. Clears as messages are read.
- Ask notification permission on first session start (not first launch).

## 7. Interoperability

- **Copy Handoff**: pasteboard gets markdown as `public.utf8-plain-text` AND rendered
  `NSAttributedString` (RTF) so pasting into rich editors looks right.
- **Save As…**: `.md` via save panel; writes through the store's export (records saved hash).
- **Drag out**: handoff header proxy-ish affordance drags a promised `planning-handoff.md`
  file; History rows with unsaved handoffs drag the same.
- **Open in editor**: URL schemes — PhpStorm `phpstorm://open?file=<abs>&line=<n>` (default),
  IntelliJ IDEA `idea://open?file=…`, VS Code `vscode://file/<abs>:<line>`, Cursor
  `cursor://file/<abs>:<line>`, custom template string with `{path}`/`{line}` placeholders.
- No Services, no Shortcuts in v1 (note as future work).

## 8. Settings & state

- **General**: editor picker (+ custom template field), IDE-plugin folder override
  (path + Choose…/Reset), notification toggles.
- **Integration**: status (shim path, skill path, installed/needs-update), Install/Reinstall
  button, explanation copy, optional "Also link into /usr/local/bin" checkbox (with proper
  auth handling or clear manual instructions if declined).
- **Updates**: Sparkle's standard automatic-check + interval UI, Check Now.
- Persisted UI state (`@AppStorage`/scene storage): split width, handoff text size, window
  frames, History sort. Session selection persists via the store (terminal selections cleared
  at launch by the engine — matches SPEC §3).

## 9. Accessibility & appearance

- Everything reachable by keyboard (feed focus, decision actions, chips, source strip).
- VoiceOver: feed rows announce kind/read state; handoff exposes headings for rotor
  navigation; status dots have text labels, never color alone (dot + label text always).
- Colors via semantic system colors; status tints: live=green, waiting=secondary,
  stopped/error=orange/red, using system palette; full light/dark + increased-contrast support.
- Reduce Motion: skip highlight-flash animation, use plain scroll.

## 10. QA checklist (manual)

1. Launch with no Tuple call → waiting screen; start a call → session appears without relaunch.
2. `chronicle say/decision` from a terminal updates the feed within a second or two, GUI open
   or closed (relaunch shows the backlog).
3. Approve from the notification while the app is in the background → skill's next `show`
   carries `decision_approved`; card shows Approved.
4. Kill the IDE mid-recording → chronicle source shows interrupted/stopped detail, no crash;
   log tail truncation never corrupts the feed.
5. ⌘C on a selected feed row; ⌥⌘C then paste into TextEdit (rich) and Terminal (plain).
6. Save As… onto Desktop; edit notes via CLI again → "Saved" pill drops; History shows
   unsaved.
7. Quit during an active call → relaunch restores session view and live updates resume;
   completed session at relaunch → waiting screen (per spec).
8. Window frame, split width, and text size survive relaunch; two displays behave.
9. Full keyboard navigation pass with Full Keyboard Access on; VoiceOver pass over feed +
   decision + handoff headings.
10. Light/dark/increased contrast; find bar; scroll position stable while Claude edits notes
    continuously.
