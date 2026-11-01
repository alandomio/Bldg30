# Todo: Linear Action Board in ModelDeck

Decisions first (see plan.md "Open decisions"):
- [ ] D1 Port rules to Swift (recommended) or shell out to Python
- [ ] D2 Linear API key in Keychain (recommended)
- [ ] D3 GitLab through `glab api` (recommended)
- [ ] D4 Native SwiftUI board (recommended) or WKWebView
- [ ] D5 Facts-only verdicts plus "Copy prompt" (recommended)
- [ ] D6 Off-by-default feature or personal fork; no Peter Park values hard-coded
- [ ] D7 Ticket state filter configurable, default In Review / Staging / To Do

Phase 1: Linear count end to end
- [x] T1 Board data model and Linear parser, tests (XCTest not run: no Xcode on this Mac; checked with a standalone harness)
- [x] T2 Linear key in Keychain plus settings field (written without Xcode: Settings card not compiled or run yet; verify at Checkpoint 1)
- [ ] T3 Linear reader, refresh loop, menu bar ticket count
- [ ] Checkpoint 1: `swift build && swift test && python3 scripts/check-localization.py`, live count correct, human review

Phase 2: GitLab end to end
- [ ] T4 GitLab facts parser, fixtures from `collect_mrs.py --format json`
- [ ] T5 glab reader with deadline and clear error states
- [ ] T6 Board page (Tickets, My MRs, Reviewing), menu shows tickets and MRs
- [ ] Checkpoint 2: page and menu agree, facts match Python collector

Phase 3: Verdicts
- [ ] T7 Port `mr_steps` rules and tests to Swift
- [ ] T8 BoardBuilder: ticket/MR linking, verdict, owner, sort
- [ ] T9 Verdict UI, act-now menu value, Open and Copy prompt
- [ ] Checkpoint 3: side by side with skill board, differences triaged

Phase 4: Polish
- [ ] T10 Manual refresh, interval, staleness, backoff, partial failure
- [ ] T11 Strings, README, CHANGELOG, VERSION 0.8.0, screenshot
- [ ] Checkpoint 4: clean build, tests green, README names new network calls
