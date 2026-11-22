# ShipDeck wire: feed producer, click pipe and freshness check

The "wire" writes ShipDeck's feed and handles the click notes the app files. The code now lives in `wire/` next to the
app and goes through the same review and tests.

The live feed still runs from the old firstmate copy until the [switch-over](#switch-over). The repo copy needs
matching organisation values and runtime paths to reproduce the old output.

## What is where

| Path | What it is |
|---|---|
| `wire/bin/wire.py` | Entry point: `feed-job`, `spawn-feed`, `dossiers`, `clicks` (the click pipe), `live`, `check-report` |
| `wire/bin/refresh.py`, `render.py`, `feed.py`, `collect_mrs.py`, `live_state.py`, `approvals.py`, `review_drafts.py`, `mr_steps.py`, `board_state.py`, `template.html` | The feed producer (pinned from ai-skills !57, with local additions 033, 034 and later) |
| `wire/bin/workers.py` | Writes `companion/workers.json` (workers of every firstmate home, read only) |
| `wire/bin/freshness.py` | [Owner wake check](#freshness-monitor) |
| `wire/bin/org.py` | Reads the organisation values (see below) |
| [`wire/schema/`](../wire/schema/) | Versioned JSON Schema files |
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
missing, the producer uses placeholder links and has no project aliases or ship rules. Supply the original values to
preserve the existing links and rules.

## Configuration

The default runtime root follows the location of `wire.py`. When running the repo copy, set the runtime and firstmate
homes as shown in the [switch-over](#switch-over) to reuse the existing state.

| Variable | Default | Used for |
|---|---|---|
| `SHIPDECK_WIRE_HOME` | the folder above `bin/` | runtime records: `state/` (locks, status, clicks.json) and `purser/` |
| `FM_HOME` | two folders above the resolved wire runtime root | the firstmate home for `wire.py` and its subprocesses, including the inbox, holds and review draft records |
| `SHIPDECK_COMPANION` | `~/Library/Application Support/ModelDeck/companion` | feed.json, feed.actions.json, inbox/, replies/, dossiers/, live.json, workers.json, commands.jsonl |
| `DECK_OFFICER_HOME` | legacy local path in [`wire.py`](../wire/bin/wire.py) | where Deck Officer comment clicks are filed |
| `SHIPDECK_OWNER_HOME` | none | `freshness.py --notify-home`: the firstmate home whose owner agent gets the stale-feed note |
| `FM_MAIN_HOME` | `~/firstmate` | `workers.py`: the main firstmate home |
| `SHIPDECK_SKILL` | `~/.claude/skills/shipdeck/shipdeck` | live MR and ticket input to `wire.py feed-job` |
| `FM_SHIPDECK_BOARD` | empty board under `state/` | optional board input to `wire.py feed-job` |
| `LINEAR_ACTION_BOARD_HOME` | `~/.config/linear-action-board` | durable decision records |

Set `SHIPDECK_ORG_CONFIG` as described under [Organisation values](#organisation-values). For standalone refresh
overrides, see [`refresh.py`](../wire/bin/refresh.py).

## Tests and the gate

Every ShipDeck change goes through no-mistakes review and validation, with automatic merge when the gate passes.
The [no-mistakes test step](../.no-mistakes.yaml) and the [CI workflow](../.github/workflows/ci.yml) both use
`bash scripts/test.sh`. While GitHub Actions runs are unavailable, run the workflow's test and packaging commands on
macOS at the pushed head and cite the local run as CI evidence.

The test script runs four checks.

1. `scripts/check-localization.py`: the English catalog.
2. `python3 -m unittest discover -s wire/tests -t wire/tests`: producer, click pipe and freshness.
3. `swift test`: the full Swift suite (XCTest and Swift Testing; needs Xcode).
4. `scripts/build.sh`: the app builds.

What the required tests prove:

- **A. Feed contract.** `wire/tests/test_feed_contract.py` renders the synthetic `producer-board.json` with the real
  producer. It validates the output against the schema and compares it with the committed feed and action mappings,
  ignoring the generation time. It checks that every valid sample feed validates, that the invalid samples
  are rejected (`invalid/`: the whole feed is wrong; `invalid-rows/`: one row is wrong), and that each emitted
  action ID has a click mapping. `Tests/ModelDeckCoreTests/FeedContractTests.swift` decodes the same files in the app: valid samples
  decode, an invalid feed is rejected, and an invalid row is skipped with a note while the rest stays. When a producer
  change is meant to change the output, run `WIRE_UPDATE_FIXTURES=1 python3 wire/tests/test_feed_contract.py`
  and commit the regenerated feed and sidecar. The app is then tested against the new shape.
- **B. Click round trip.** `Tests/ModelDeckCoreTests/ClickRoundTripTests.swift` uses the app's code to send decision
  options, free answers, Add context, review drafts, MR and ticket row buttons, and worker controls through
  `ClickSender`. Deck Officer comments go straight to `CompanionInbox`. The harness runs the real `wire.clicks()`
  against temporary main and Deck Officer homes with stub inbox commands that acknowledge and answer the notes.
  The app reads completion through `CommandLedger` for commands and `CompanionReply` for comments.
  `wire/tests/test_click_roundtrip.py` drives the same pipe and checks the filed notes for the expected work item and home.
- **C. Gate.** The whole suite plus the build, as above. Every bug fix adds a test that failed before the fix.
- **D. Freshness.** `wire/tests/test_freshness.py` covers the owner wake check. `Tests/ModelDeckCoreTests/FreshnessTests.swift`
  checks the app's age thresholds and menu bar summary.

`wire/tests/test_hold_clicks.py` drives the real `bin/fm-captain-hold.sh` of a firstmate checkout. It runs only when
`FM_ROOT_FOR_TESTS` points at one, because CI has no firstmate checkout.

## Freshness monitor

`freshness.py` reads `generated_at` and stays silent through 30 minutes. For an older generation or a missing or
unreadable feed, it prints one line and exits 1. A watcher check script turns that line into a wake. The check records
the reported timestamp (or unreadable state) and suppresses repeats until the feed is fresh again or a different
generation is reported.
To wake the ShipDeck owner agent, install the check in the owner's firstmate home as `state/shipdeck-feed-fresh.check.sh`:

```sh
#!/usr/bin/env bash
python3 "/path/to/repo/wire/bin/freshness.py" --state "/path/to/firstmate/data/shipdeck-wire/state/freshness.json" 2>&1
exit 0
```

For a custom feed path, pass `--feed` or set `SHIPDECK_COMPANION` to its containing folder when the filename is
`feed.json`. If another home runs the check, add `--notify-home <owner's firstmate home>` (or set
`SHIPDECK_OWNER_HOME`). The check files a note in that home's inbox and retries on the next check if filing fails.
See [feed freshness in the app](companion/README.md#feed-freshness) for what users see.

## Switch-over

The running feed and click pipe still use `<firstmate>/data/shipdeck-wire/bin`. To move them to this repo:

1. Create the organisation config at `~/.config/shipdeck/org.json` with the values the old copy has in code: GitLab
   group and Linear workspace from `feed.py` `LINEAR_BASE` and `collect_mrs.py`, short names from `render.py`
   `PROJECTS`, ticket prefixes from `render.py` `REF`, the two lists from `bin/ships.json`, and as `knowledge_search`
   the search the old "Add context" prompts name (in `wire.py` and `render.py`). Check it with
   `SHIPDECK_ORG_CONFIG=~/.config/shipdeck/org.json python3 -c 'import sys; sys.path.insert(0, "wire/bin"); import org; print(org.ORG)'`.
2. Dry run without touching the live feed. Run each copy of `render.py` with the same board and captured inputs, and
   pass separate scratch output paths for the HTML and `--feed`. Compare the HTML, feed and action sidecar, ignoring
   `generated_at` in the JSON.
3. In `<firstmate>/state/shipdeck-feed.check.sh` and `shipdeck-clicks.check.sh`, point `W=` at `<repo>/wire/bin/wire.py`
   and export `SHIPDECK_WIRE_HOME=<firstmate>/data/shipdeck-wire` and `FM_HOME=<firstmate>`. The runtime state stays in
   the old folder, so locks, `clicks.json` and the purser files carry over.
4. Keep the app's feed and inbox settings pointed at the existing output files. If they use a custom companion
   directory, pass the same directory as `SHIPDECK_COMPANION` to the wire checks.
5. Install the freshness check in the owner's home and point it at the same feed.
6. Watch one feed refresh and one click end to end (`state/feed.status.json`, `commands.jsonl`). To roll back,
   point the firstmate check scripts back at the old path.
7. When the new path has run cleanly for a week, the old `bin/` and `schema/` can be archived. That is the firstmate
   owner's call: nothing in this repo deletes them.
