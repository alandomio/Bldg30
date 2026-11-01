# PLAN: firstmate companion (version 1)

Source: PRD.md (same folder). Two tracks run in parallel against one shared contract.

## 0. Contract (both tracks, first)

`companion-feed.v1` JSON at a path the app reads (default `~/Library/Application Support/ModelDeck/companion/feed.json`, written atomically):

- `schema: "companion-feed.v1"`, `generated_at`, `producer`
- `decisions[]`: `id`, `title`, `project`, `why_now`, `options[] {label, consequence}`, `recommendation`, `links[]`, `urgent: bool`
- `mrs[]`: `ref`, `url`, `title`, `role: author|reviewer`, `verdict` (close|notyet|blocked|hold), `label`, `next_owner`, `pipeline`, `open_threads`, `drafts[] {id, target_url, text}`, `actions[] {id, label, outward: bool}`
- `tickets[]`: `identifier`, `url`, `title`, `status`, `finish {step, owner}`, `linked_mrs[]`, `actions[]`

Inbox note (app to firstmate), one JSON per click: `schema: "companion-click.v1"`, `idempotency_key`, `action_id`, `target`, `draft_text` (exact, if any), `created_at`.

Change event (app to firstmate), JSON lines: `schema: "companion-event.v1"`, `fingerprint` (stable hash of source+id+state), `kind` (new_comment|review_requested|pipeline_changed|ticket_state|mr_merged), `ref`, `at`. Batched, at most one flush per 5 minutes.

A JSON Schema file for all three lives in both repos; both sides validate.

## Track A: firstmate side

Repos: ai-skills (linear-action-board skill), firstmate home (private config only).

1. **Feed writer in the skill.** Add `render.py --feed <path>` (or a sibling `feed.py`) that writes `companion-feed.v1` from the same `board.json` and collect facts. Reuse every existing rule (verdict validation, drafts, no merged cards, every row actionable). Tests next to the existing ones.
2. **Decisions source.** Read firstmate captain holds (`bin/fm-tasks-axi.sh` / captain-hold records) into `decisions[]`, through firstmate's own read commands only.
3. **Scheduled refresh.** A script that runs `collect_mrs.py` plus a Linear fetch with the read-only key from the Keychain, then writes the feed. Run it from firstmate monitoring or launchd every 5 minutes.
4. **Click handling.** Document how firstmate handles `companion-click.v1` inbox notes (map `action_id` to the existing board prompts; outward actions keep the "show exact text, wait for Alan" rule unless the click carries Alan's approved draft text).
5. **Event source.** Register the app's events file as a firstmate process-event source with fingerprint dedupe.

Delivery: ai-skills MR (no-mistakes or direct-PR per registry); firstmate private config only.

## Track B: ModelDeck side

Repo: Bldg30 (ModelDeck), branch per change.

1. **Feed reader** in `ModelDeckCore`: decode and validate `companion-feed.v1`; staleness from `generated_at`. Unit tests with fixture feeds (valid, invalid, stale).
2. **Panels**: Decisions (one card at a time, options, recommendation), My MRs and reviews (verdict pill, next owner, drafts behind a toggle, buttons), My tickets (status, step left to Done). Localized Italian and English like the rest.
3. **Buttons** write `companion-click.v1` notes into firstmate's inbox path (configurable, no firstmate paths hard-coded), show "sent / picked up / done" from firstmate's reply.
4. **Polling and events**: extend `LinearBoard` and add a GitLab reader with a personal token in the Keychain; diff against last poll; write `companion-event.v1` with fingerprints, batched.
5. **Badge and notifications**: menu bar count of decisions waiting; macOS notification only for `urgent: true`.

Build note: Command Line Tools build needs `MODELDECK_SDK=.../MacOSX26.5.sdk MODELDECK_BUILD_SYSTEM=native` until Xcode is installed; XCTest needs full Xcode, so keep core logic testable with the existing test setup and say what could not run.

## Version 2 (not now)

Health panel (MCP servers, CLI logins, firstmate monitoring), workers panel (stuck on prompt, quiet too long, exact prompt text, "ask firstmate" button). App as MCP server: later still.

## Order and gates

1. Contract and schema agreed (Track A writes it, Track B consumes the same file).
2. A1 + B1 in parallel against fixture feeds.
3. A3 + B2/B3 integration on Alan's Mac.
4. A5 + B4 events.
5. B5 badge and notifications.
Nothing posts, approves or merges without Alan's word; clicks only file inbox notes.
