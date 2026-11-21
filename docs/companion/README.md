# Command Bridge (version 1)

ShipDeck renders a feed that a companion tool writes. See the [PRD](PRD.md) and [original plan](PLAN.md) for the design decisions.

## Setup
Command Bridge is off by default. The default feed path is `~/Library/Application Support/ModelDeck/companion/feed.json`. Sending actions requires an existing, writable inbox folder. The path overrides `--feed`, `--inbox`, `--fm-home` and `--workers-cache` fall back to their normal settings or defaults when given without a value.
Demo mode shows `CompanionFixture`; `fixture-feed.json` is the same content for manual tests.

## Contract
- `companion-feed.v1` is read from the feed file. The whole feed is rejected if the JSON is unreadable, the schema name differs from `companion-feed.v1`, or a required top-level field is missing or invalid. `generated_at` must be a valid ISO 8601 timestamp, `producer` a string, and `decisions`, `mrs` and `tickets` arrays. The optional `warnings` field must be an array of strings or null. Invalid rows are skipped and counted. Examples include an unknown verdict, a disallowed URL, a missing required field or a duplicate row identifier. The other rows still show. A feed older than 15 minutes shows an amber note and pill and stops sending urgent decision notifications. Its content stays readable and clickable.
- `companion-click.v1` writes one `<epoch>-<key>.json` note per click, atomically. See [CompanionClick.swift](../../Sources/ModelDeckCore/CompanionClick.swift) for the note fields.
- `companion-event.v1`: JSON lines appended to the events file (Settings, optional), deduplicated by fingerprint, flushed at most every 5 minutes, 50 lines per flush. Kinds: `review_requested`, `pipeline_changed`, `new_comment` (more unresolved threads), `ticket_state`, `mr_merged` (an MR that left the open lists and GitLab reports as merged). The first poll after launch is a silent baseline.
- **Add context** writes `<ref>.add-context` with the decision id, MR ref or ticket identifier as `target`. A free answer with no option uses `<decision id>.answer`. In either case, the app sends typed text in `draft_text` after trimming trailing whitespace.
- A decision option uses its supplied `action_id` or falls back to `decision:<id>:option:<zero-based index>`. The option label supplies `draft_text` when no answer text is entered. MR and ticket row buttons use the feed action id and the row ref or ticket identifier. Posting sends the shown draft text and the MR ref. A review draft with a matching action id ending in `.comment-<draft id>` uses that action when each draft has a match. **Post all** confirms once and sends one click per remaining draft. The legacy draft panel uses the row's post action.
- See the [command lifecycle](../../COMMANDS.md) for click status and send failures.
- See the [feed decoder](../../Sources/ModelDeckCore/CompanionFeed.swift) for row fields and validation rules.

## Decision dates
A decision may carry `created_at` (YYYY-MM-DD). The card header shows the date and age. The age turns amber after 14 days and red after 30. Urgent decisions come first, then High, then the rest. Within each priority, the card menu switches between feed order and oldest first with undated decisions last. ShipDeck remembers the choice.

## Working through cards

On a decision card, a letter key submits its option immediately. Use Up or Down to select an option and Enter to submit it. **Drop** gives you five seconds to undo before sending. If sending fails, the decision reappears and ShipDeck displays the error. In **MRs and reviews**, use the left and right arrows to page through MRs in close-rank order. Expand **Waiting on others** to see approved MRs waiting for someone else to merge. **Details** expands context and history on MR and ticket cards. Open the dossier with the card title or chevron.

## Own polling (1.1)
While the app is open and the Command Bridge is on, it polls every 2 minutes, read-only. Linear: the existing key in the Keychain (Settings, Linear). GitLab: host (https only, localhost may use http), optional username and a read-only personal token in the Keychain; it reads open MRs authored by you and waiting for your review (pipeline status, unresolved threads). A successful poll newer than the feed supplies the current pipeline, unresolved thread count and ticket status for matching rows. ShipDeck marks the verdict stale if a tracked value changes, the item was updated after the feed was generated, or the item is absent from the newer poll. Equivalent pipeline states such as `success` and `passed` count as the same state. MRs and tickets only in the poll show with "Nessun verdetto". Failed sources keep their last rows and show the error.

## Dossier
The dossier lives at `dossiers/<name>.json` beside the feed. For example, `svc !12` maps to `svc-12.json` and `IN-1` maps to `in-1.json`. Only `generated_at` is required. See the [dossier decoder](../../Sources/ModelDeckCore/Dossier.swift) for filename normalization and optional fields.

A missing file shows an empty state. A malformed file shows an error. The MR card prefers the feed's next action and falls back to the dossier. Last activity uses the newest available date from the poll, the feed row or the dossier's last timeline entry.

## Workers

The **Workers** tab reads records from the local firstmate home (default `~/firstmate`, overridable with `--fm-home <path>`). It groups workers by current state. Workers whose activity is over 24 hours old or unknown can appear in the idle group. Remote workers are read-only.

ShipDeck calls local firstmate tools to refresh crew state, peek at a terminal, interrupt, exit or relaunch an agent. In-app prompt answers require firstmate's `prompt` and `answer` verbs, with a prompt hash check at submission. When those verbs are unavailable, open the terminal to answer. Steering, sweeping and discarding after refused cleanup send inbox notes for firstmate to handle. If a steering note fails to send, ShipDeck shows the error and keeps your text. Sweep is available for done or idle local workers with no unposted drafts or open decisions. **Sweep**, **Sweep all** and **Discard and clean up** skip any worker with a queued or picked-up worker command. Review the loss summary before confirming a discard.

## Icon
`assets/icon-r1*.svg` are the sources; `scripts/generate-icon.swift` renders the icon, the menu bar template glyph and the sidebar logo. `scripts/build.sh` renders them into `build/` and leaves `assets/` untouched. Run `scripts/refresh-assets.sh` to update the tracked files in `assets/` on purpose.
