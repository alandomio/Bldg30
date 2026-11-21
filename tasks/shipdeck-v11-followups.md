# Change spec: ShipDeck 1.1 follow-ups that need no product decision

Each item has an acceptance criterion and the test that proves it.

| Follow-up | Acceptance criterion | Proving test |
|---|---|---|
| `pipeline-vocab-false-stale` | Feed "success" and poll "passed" (and other same-meaning words) do not mark a verdict stale. | `BridgeTests.sameMeaningPipelineWordsFromFeedAndPollDoNotMarkVerdictStale` |
| `localization-test-scans-source` | No test reads source text. English.json contract stays; lookup and fallback are tested. | `LocalizationCoverageTests` (three tests) |
| `unused-duplicate-helpers` | Dead paths removed. The banner and the card status text each have one implementation, used by the view and by the tests. | `bannerNamesTheLiveApproversAndSaysYouOnlyWhenTheUserApproved`, `plainStatusWords` |
| `build-writes-tracked-assets` | After `bash scripts/build.sh`, no tracked file changed. | `scripts/check-build-clean.sh` |
| `drop-hidden-after-failed-send` | A Drop whose send fails shows the decision again. | `FollowUpTests.aDropComesBackWhenItsSendFails` |
| `queued-line-before-inbox-check` | With no inbox folder, nothing is written and the error shows. | `FollowUpTests.noInboxFolderMeansNoQueuedLineAndAnError` |
| `docs-contradict-contract` | `docs/companion/README.md` matches the code (skipped rows, `commands.jsonl`, icon step). | Review of the text; no test. |
| `sweep-repeatable-while-queued` | Sweep, Sweep all and Discard do nothing while a command for that worker is queued or picked up. | `FollowUpTests.workerActionsWaitForTheCommandInFlight` |
| `argv-index-crash` | A flag with no value reads as absent; no crash. | `FollowUpTests.aFlagWithoutAValueReadsAsAbsent` |

Left for a product decision: `dismissal-fingerprint-flaps`, `mr-row-actions-ignore-stale-verdict`.
