# Command Bridge (version 1)

ModelDeck renders a feed that a companion tool writes. See PRD.md and PLAN.md here for the decisions.

## Setup
Settings, Command Bridge: turn it on, set the feed file (default `~/Library/Application Support/ModelDeck/companion/feed.json`) and the inbox folder. No inbox folder, no buttons. Off by default.
Demo mode shows `CompanionFixture`; `fixture-feed.json` is the same content for manual tests.

## Contract
- `companion-feed.v1`: read from the feed file, strict (unknown verdict, non-https URL, missing field or duplicate id rejects the whole feed). Older than 15 minutes is stale: greyed out, buttons disabled, no notifications.
- `companion-click.v1`: one `<epoch>-<key>.json` per click in the inbox folder, written atomically. Option buttons use `action_id` `decision:<id>:option:<n>` with the label as `draft_text`; draft buttons use `draft:<id>` with the exact text.
- `companion-event.v1`: JSON lines appended to the events file (Settings, optional), deduplicated by fingerprint, flushed at most every 5 minutes, 50 lines per flush. Kinds: `review_requested`, `pipeline_changed`, `new_comment` (more unresolved threads), `ticket_state`, `mr_merged` (an MR that left the open lists and GitLab reports as merged). The first poll after launch is a silent baseline.
- `companion-click.v1` with `action_id` `add_context`: `target` is the MR ref or ticket identifier, `draft_text` the typed note.
- Click status is inferred from files: in the inbox is sent, moved to `handled/` is picked up, a `<name>.reply.json` beside it is done. The producer must follow this.
- The JSON Schema files from the ai-skills worker did not exist yet; the code follows PLAN section 0.

## Own polling (1.1)
While the app is open and the Command Bridge is on, it polls every 2 minutes, read-only. Linear: the existing key in the Keychain (Settings, Linear). GitLab: host (https only, localhost may use http), optional username and a read-only personal token in the Keychain; it reads open MRs authored by you and waiting for your review (pipeline status, unresolved threads). A poll newer than the feed overrides pipeline, threads and ticket status; the verdict is then marked "Verdetto superato" and its action buttons are disabled. MRs and tickets only in the poll show with "Nessun verdetto". Failed sources keep their last rows and show the error.

## Dossier
Clicking an MR or ticket opens its dossier from `dossiers/<name>.json` beside the feed file. `<name>` is the ref with every run of characters outside letters, digits, `.`, `_`, `-` replaced by one `-`: `svc !12` is `svc-12.json`, `IN-1` is `IN-1.json`. Only `generated_at` is required; the rest is optional:
`{"summary":"","timeline":[{"at":"","text":""}],"open_decisions":[""],"gotchas":[""],"links":[{"label":"","url":"https://…"}],"next_action":"","generated_at":"2027-01-15T08:00:00Z"}`
A missing file shows an empty state; a malformed one shows the error. "Aggiungi contesto" files the `add_context` click.

## Icon
`assets/icon-r1*.svg` are the sources; `scripts/generate-icon.swift` (run by `scripts/build.sh`) renders `assets/AppIcon.icns`, the menu bar template glyph and the sidebar logo.
