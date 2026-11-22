# ShipDeck wire: feed producer, click pipe and freshness check

ShipDeck only renders a feed file and files one click note per button. The code that writes the feed and handles the
clicks is the "wire". It lived outside version control in the firstmate home (`<firstmate>/data/shipdeck-wire`). It now
lives in this repo, in `wire/`, next to the app, so that every change to it goes through the same review and tests as the app.

The live feed still runs from the old location until the switch-over below. The two copies behave the same.

## What is where

| Path | What it is |
|---|---|
| `wire/bin/wire.py` | Entry point: `feed-job`, `spawn-feed`, `dossiers`, `clicks` (the click pipe), `live`, `check-report` |
| `wire/bin/refresh.py`, `render.py`, `feed.py`, `collect_mrs.py`, `live_state.py`, `approvals.py`, `review_drafts.py`, `mr_steps.py`, `board_state.py`, `template.html` | The feed producer (pinned from ai-skills !57, with local additions 033, 034 and later) |
| `wire/bin/workers.py` | Writes `companion/workers.json` (workers of every firstmate home, read only) |
| `wire/bin/freshness.py` | Freshness check: wakes the owner agent when the feed is older than 30 minutes |
| `wire/bin/org.py` | Reads the organisation values (see below) |
| `wire/schema/*.schema.json` | The contract: `companion-feed.v1`, `companion-click.v1`, `companion-reply.v1`, `companion-live.v1`, `companion-dossier.v1`, `companion-event.v1` |
| `wire/fixtures/feeds/` | Synthetic sample feeds shared by the Python and Swift tests (no real names, tokens or customer data) |
| `wire/tests/` | Python tests (stdlib `unittest`) |
| `wire/org.example.json` | Shape of the organisation config |

Not copied: the `*.orig*` and `*.backup*` files (old versions kept by hand), `__pycache__`, the runtime `state/` folder,
and `ships.json` (now the `ships` key of the organisation config). `PINNED_FROM_57.txt` recorded the pin to ai-skills
commit `2da0d7ed` plus local changes; that history is summarized in this paragraph.

## Organisation values

This repository is public, and decision D6 in `tasks/todo.md` says no company values are hard-coded here. The GitLab
group, the Linear workspace, the short project names (`pi !12`), the ticket prefixes, the projects where a merge
does not reach production and the knowledge search named in the "Add context" prompt (`knowledge_search`) are read from
a local JSON file:
`$SHIPDECK_ORG_CONFIG`, or else `~/.config/shipdeck/org.json`. `wire/org.example.json` shows the shape. If the file is
missing, neutral example values apply, and links and project names will be wrong. If the file is present, the producer
behaves exactly as the original copy did.

## Configuration

Every path has a default. With no variables set, each one resolves as before from where `wire.py` lives.

| Variable | Default | Used for |
|---|---|---|
| `SHIPDECK_WIRE_HOME` | the folder above `bin/` | runtime records: `state/` (locks, status, clicks.json) and `purser/` |
| `FM_HOME` | two folders above `SHIPDECK_WIRE_HOME` | the firstmate home: `bin/fm-inbox.sh`, `bin/fm-captain-hold.sh`, `state/*.status`, `data/` records |
| `SHIPDECK_COMPANION` | `~/Library/Application Support/ModelDeck/companion` | feed.json, feed.actions.json, inbox/, replies/, dossiers/, live.json, workers.json, commands.jsonl |
| `SHIPDECK_ORG_CONFIG` | `~/.config/shipdeck/org.json` | organisation values |
| `DECK_OFFICER_HOME` | `~/.treehouse/firstmate-753674/3/firstmate` | where Deck Officer comment clicks are filed |
| `SHIPDECK_OWNER_HOME` | none | `freshness.py --notify-home`: the firstmate home whose owner agent gets the stale-feed note |
| `FM_MAIN_HOME` | `~/firstmate` | `workers.py`: the main firstmate home |
| `SHIPDECK_SKILL`, `FM_SHIPDECK_BOARD`, `COMPANION_*`, `LINEAR_ACTION_BOARD_HOME` | as before | unchanged, see the module docstrings |

## Tests and the gate

`bash scripts/test.sh` is the gate. CI (`.github/workflows/ci.yml`) and the no-mistakes pipeline run it, and every
change runs it before it merges:

1. `scripts/check-localization.py`: the English catalog.
2. `python3 -m unittest discover -s wire/tests -t wire/tests`: producer, click pipe and freshness.
3. `swift test`: the full Swift suite (XCTest and Swift Testing; needs Xcode).
4. `scripts/build.sh`: the app builds (skip with `--no-build` while iterating).

What the required tests prove:

- **A. Feed contract.** `wire/tests/test_feed_contract.py` renders the synthetic `producer-board.json` with the real
  producer. It checks that the output validates against `companion-feed.v1` and equals the committed
  `producer.feed.json` and `producer.feed.actions.json`, that every sample feed validates, that the invalid samples
  are rejected (`invalid/`: the whole feed is wrong; `invalid-rows/`: one row is wrong), and that every button has a
  click mapping. `Tests/ModelDeckCoreTests/FeedContractTests.swift` decodes the same files in the app: valid samples
  decode, an invalid feed is rejected, and an invalid row is skipped with a note while the rest stays. When a producer
  change is meant to change the output, run `WIRE_UPDATE_FIXTURES=1 python3 -m unittest discover -s wire/tests -t wire/tests`
  and commit the new fixtures. The app is then tested against the new shape.
- **B. Click round trip.** `Tests/ModelDeckCoreTests/ClickRoundTripTests.swift` builds the click of every button of
  every sample feed with the app's own code (decision options, free answer, Add context, review drafts, MR and ticket
  row buttons) and sends it with `ClickSender`, which writes the `queued` line and the inbox note. It then runs
  `wire/tests/click_roundtrip.py`, which passes the clicks through the real `wire.clicks()` against a temporary
  firstmate home with a stub `fm-inbox.sh`, writing to the same `commands.jsonl`, then acknowledges and answers each
  note. The test checks that the note names the right work item and that the app's `CommandLedger` reads every click as
  `done`. `wire/tests/test_click_roundtrip.py` runs the same pipe with clicks built in Python.
- **C. Gate.** The whole suite plus the build, as above. Every bug fix adds a test that failed before the fix.
- **D. Freshness.** `wire/tests/test_freshness.py` covers `freshness.py`. `Tests/ModelDeckCoreTests/FreshnessTests.swift`
  covers the app's 30-minute outdated state (red badge in the panel, "Feed fermo" in the menu bar).

`wire/tests/test_hold_clicks.py` drives the real `bin/fm-captain-hold.sh` of a firstmate checkout. It runs only when
`FM_ROOT_FOR_TESTS` points at one, because CI has no firstmate checkout.

## Freshness monitor

`freshness.py` stays silent while `feed.json` is younger than 30 minutes. When the feed is older, missing or unreadable,
it prints one line and exits 1. It does this once per stale feed. A watcher check script turns that line into a wake.
To wake the ShipDeck owner agent, install the check in the owner's firstmate home as `state/shipdeck-feed-fresh.check.sh`:

```sh
#!/usr/bin/env bash
# ShipDeck feed freshness: one line (a wake) when feed.json is older than 30 minutes; silent otherwise.
python3 <repo>/wire/bin/freshness.py --state <firstmate>/data/shipdeck-wire/state/freshness.json 2>&1
exit 0
```

If another home runs the check, add `--notify-home <owner's firstmate home>` (or set `SHIPDECK_OWNER_HOME`). The check
then also files one note in that home's inbox, which wakes the owner agent there. The app shows the same condition as a
red "Feed fermo da N min" badge in the companion panel and a "Feed fermo" reading in the menu bar.

## Switch-over (follow-up, not done by this change)

The running feed and click pipe still use `<firstmate>/data/shipdeck-wire/bin`. To move them to this repo:

1. Create the organisation config at `~/.config/shipdeck/org.json` with the values the old copy has in code: GitLab
   group and Linear workspace from `feed.py` `LINEAR_BASE` and `collect_mrs.py`, short names from `render.py`
   `PROJECTS`, ticket prefixes from `render.py` `REF`, the two lists from `bin/ships.json`, and as `knowledge_search`
   the search the old "Add context" prompts name (in `wire.py` and `render.py`). Check it with
   `SHIPDECK_ORG_CONFIG=~/.config/shipdeck/org.json python3 -c 'import sys; sys.path.insert(0, "wire/bin"); import org; print(org.ORG)'`.
2. Dry run without touching the live feed. Render the current board into a scratch file with both copies and compare
   the feeds (ignore `generated_at`).
3. In `<firstmate>/state/shipdeck-feed.check.sh` and `shipdeck-clicks.check.sh`, point `W=` at `<repo>/wire/bin/wire.py`
   and export `SHIPDECK_WIRE_HOME=<firstmate>/data/shipdeck-wire` and `FM_HOME=<firstmate>`. The runtime state stays in
   the old folder, so locks, `clicks.json` and the purser files carry over.
4. Point ShipDeck's own wire command (the app runs `wire.py clicks` after each click and `wire.py live`) at the repo
   copy, with the same two variables.
5. Install the freshness check (above) in the owner's home.
6. Watch one feed refresh and one click end to end (`state/feed.status.json`, `commands.jsonl`). To roll back, point
   both check scripts and the app back at the old path.
7. When the new path has run cleanly for a week, the old `bin/` and `schema/` can be archived. That is the firstmate
   owner's call: nothing in this repo deletes them.
