# 0001: Test gate, feed producer and click pipe in the repo

## Problem

ShipDeck showed wrong state, had buttons that did nothing, regressed after new builds, and showed feeds older than 30
minutes. Changes merged without review or tests. The feed producer and the click pipe lived outside version control in
the firstmate home, so nothing tested the contract between them and the app.

## Acceptance criteria

- [x] The producer and click pipe are in `wire/` (copied, not moved). Paths and organisation values are configurable,
      and with the organisation config present the output is identical to the old copy.
- [x] One schema (`wire/schema/companion-feed.v1.schema.json`) and synthetic sample feeds (`wire/fixtures/feeds`). The
      producer's output validates against the schema, and the app decodes the same files.
- [x] Every button type (decision option, free answer, Add context, review draft, MR and ticket row action) writes a
      click that the real click pipe matches to the right work item, files, acknowledges and answers, end to end on a
      temporary folder, and the app's command ledger reads it as done.
- [x] `bash scripts/test.sh` runs translations, the wire tests, the full Swift suite and the app build. CI and the
      no-mistakes test step (`.no-mistakes.yaml`) run it.
- [x] A feed older than 30 minutes wakes the owner agent (`wire/bin/freshness.py`) and shows a red badge in the app.
- [x] `docs/companion/PRD.md` and `PLAN.md` match the firstmate copies; `docs/shipdeck-wire.md` documents the layout,
      configuration, tests and the switch-over.

## Proving tests

- Feed contract: `Tests/ModelDeckCoreTests/FeedContractTests.swift` and `wire/tests/test_feed_contract.py`. On the
  main branch before ShipDeck 1.1 the app test failed: the decoder rejected `pipeline: null`, which the producer writes
  for an MR without pipeline facts. ShipDeck 1.1 fixed the decoder; the test now guards that contract.
- Click round trip: `Tests/ModelDeckCoreTests/ClickRoundTripTests.swift` and `wire/tests/test_click_roundtrip.py`. On
  the main branch before ShipDeck 1.1 the option and draft buttons sent ids the pipe could not map. ShipDeck 1.1 fixed
  the ids; the test now guards every button type end to end.
- Freshness: `wire/tests/test_freshness.py` and `Tests/ModelDeckCoreTests/FreshnessTests.swift`. Both failed before
  this change (no freshness check, no outdated state in the app).
- Gate: `scripts/test.sh`.

## Out of scope

New features, UI redesign, UI snapshot tests, and switching the live feed to the repo copy (steps in
`docs/shipdeck-wire.md`). This change does not touch the firstmate repo.
