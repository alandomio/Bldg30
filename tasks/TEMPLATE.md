# NNNN: <short title>

Copy this file to `tasks/NNNN-<slug>.md` (next free number) in the same change. Keep it short: a reviewer reads it
before the diff.

## Problem

What is wrong or missing, seen from the user. One paragraph. Name the symptom (wrong state, a dead click, a regression,
a stale feed) and where it shows.

## Acceptance criteria

- [ ] Observable result 1 (what the user sees or what a file contains)
- [ ] Observable result 2
- [ ] `bash scripts/test.sh` passes

## Proving test

The test that fails before this change and passes after it, with its file and name, for example
`Tests/ModelDeckCoreTests/FeedContractTests.swift: producerOutputWithUnknownPipelineAndThreadsDecodes` or
`wire/tests/test_click_roundtrip.py: test_every_button_of_every_sample_reaches_its_work_item_and_is_answered`.
A bug fix always adds one. If no automatic test can prove it (UI layout, for example), say why and how it was checked.

## Out of scope

What this change does not do, so nobody waits for it.
