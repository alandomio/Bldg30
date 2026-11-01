# Plan: Linear Action Board in ModelDeck

Status: draft for review. No code written yet.

## Goal

Show the user's open Linear tickets and GitLab merge requests (MRs) inside ModelDeck: a count in the menu bar, and a board page in the dashboard where every row has a verdict, an owner and one next action. Same facts and rules as the `linear-action-board` skill, read live, never guessed.

Out of scope for v1: posting, approving, merging or messaging from the app; Lavish live updates; claude.ai artifact publishing; Nevermind/Add context/Wait-what buttons; the `ships.json` "merged, not applied" tracking. The app may open URLs and copy prompts, nothing outward.

## Architecture findings

- SwiftPM package, two targets: `ModelDeckCore` (pure logic, parsers, readers; tested) and `ModelDeck` (SwiftUI app, menu bar, dashboard). XcodeGen `project.yml` mirrors it. macOS 14, no package dependencies, not sandboxed.
- Build: `swift build`, `swift test`, `bash scripts/build.sh` (produces `build/ModelDeck.app`). Localization strings live in `Sources/ModelDeckCore/Resources/English.json` and are checked by `python3 scripts/check-localization.py`. Italian is the default UI language.
- `DeckStore` (`@MainActor ObservableObject`) owns state and refresh loops (`Task` + `Task.sleep`, interval from `UserDefaults`). Secrets go through `DeckKeychain` (generic password, per-account) in `DeckStore.swift`.
- External data readers live in Core as enums with a pure `parse(Data)` plus a reader that shells out with `Process` and a deadline (`CodexUsage`, `ClaudeBridge`). Tests feed JSON fixtures to `parse`.
- Menu bar text comes from `MenuBarSummary` / `MenuBarOptions` (Codable in UserDefaults), rendered by `MenuBarBadge`; settings in `MenuBarSettingsView` and `SettingsView`. Dashboard pages are SwiftUI views in `Dashboard.swift`.

## Source feature findings

- GitLab: `collect_mrs.py` calls `glab api` for MRs authored by and reviewed by the user, then per MR: MR, `/approvals`, `/discussions`, `/commits`. It produces facts (merge status, approvers, open threads with `next_move`, user's last comment, commit after it, head pipeline and whether it ran on the head SHA).
- Rules are pure and small: `mr_steps.step()` (rebase, rework, fix_pipeline, fix_threads, review), `merge_state()`, `step_from_label()`. About 100 lines to port. Tests exist in `tests/test_steps.py`.
- Linear: the skill reads tickets through the Linear MCP server (no CLI token). The app needs its own path: Linear GraphQL API (`https://api.linear.app/graphql`) with a personal API key.
- Verdicts (`close`, `notyet`, `blocked`, `hold`), headlines and "next" text are written by the model in the skill. The app can only derive the fact-based part. delivery-buddy's next step for a ticket is also model judgment plus live checks; in the app it becomes "inherit the step of the linked MR, else show status".

## Components and dependency graph

```
Keychain (Linear key)      glab CLI (existing auth)
        |                          |
 LinearClient (Core)        GitLabClient (Core)
        |                          |
        +------> BoardModel <------+     MRSteps (Core, ported rules)
                    |                       |
                 BoardBuilder (Core: link tickets<->MRs, verdict, next action)
                    |
              DeckStore.board + refresh loop (App)
              /                 \
   MenuBarSummary "board" value   BoardView page in Dashboard
              \                 /
            Settings (key, interval, toggle), English.json strings
```

Build order: data model and pure rules first (testable without network), then one client at a time, each wired straight through to UI.

## Phases and tasks

### Phase 1: Linear ticket count end to end

**T1. Board data model and Linear parser (Core)**
- Description: `BoardTicket` (id, identifier, title, state name, url, updatedAt) and `LinearBoard.parse(Data)` for the GraphQL `viewer.assignedIssues` response, filtered to state types not completed/canceled.
- Acceptance: parses a fixture; unknown or missing fields give an error, not zero tickets.
- Verify: `swift test --filter LinearBoardTests`.
- Depends on: none. Files: `Sources/ModelDeckCore/LinearBoard.swift`, `Tests/ModelDeckCoreTests/LinearBoardTests.swift`.

**T2. Linear key in Keychain plus settings field**
- Description: `DeckKeychain` account `linear`; a secure field in Settings to paste, save and clear the key.
- Acceptance: key survives restart; clearing removes the item; key never logged or written to UserDefaults.
- Verify: `swift build`; manual: save, relaunch, `security find-generic-password -s <service> -a linear` finds it.
- Depends on: none. Files: `DeckStore.swift`, `SettingsView.swift`, `English.json`.

**T3. Linear reader and menu bar ticket count**
- Description: `LinearBoard.read(token:)` via `URLSession` POST with a 10s timeout. `DeckStore` refreshes on its own interval (default 5 min). New `MenuBarOptions` value "Board" showing ticket count, `—` when unavailable, `*` when stale (same rules as quotas).
- Acceptance: with a valid key the menu bar shows the number of open assigned tickets; bad key shows `—` and an error in the tooltip; no request when the value is off and the page is closed.
- Verify: `swift test`; `bash scripts/build.sh && open build/ModelDeck.app`; compare count with Linear "My issues".
- Depends on: T1, T2. Files: `LinearBoard.swift`, `DeckStore.swift`, `MenuBarSummary.swift`, `MenuBarBadge.swift`, `MenuBarSettingsView.swift`, `English.json`, `MenuBarTests.swift`.

**Checkpoint 1:** `swift build && swift test && python3 scripts/check-localization.py` green; app shows a correct live count; human reviews the Keychain and network approach before GitLab work.

### Phase 2: GitLab MRs end to end

**T4. GitLab facts parser (Core)**
- Description: `MRFacts` struct matching `collect_mrs.py` output fields; parsers for MR list, approvals, discussions, commits; derive `open_threads.next_move`, `commit_after_user_comment`, `sha_matches_head`.
- Acceptance: fixtures copied from a real `collect_mrs.py --format json` run produce identical facts.
- Verify: `swift test --filter GitLabFactsTests`.
- Depends on: none. Files: `Sources/ModelDeckCore/GitLabFacts.swift`, tests plus fixture JSON.

**T5. glab reader**
- Description: locate `glab` (`/opt/homebrew/bin`, `/usr/local/bin`), run `glab api` with a deadline like `CodexUsage`, get username from `glab api user`, then list authored and reviewing open non-draft MRs and fetch per-MR detail concurrently (cap 4).
- Acceptance: missing glab or `glab auth status` failure shows a clear error state, never an empty list.
- Verify: `swift test`; manual run against own account, diff against `python3 ~/.claude/skills/linear-action-board/collect_mrs.py --format json`.
- Depends on: T4. Files: `GitLabFacts.swift` (reader), `DeckStore.swift`.

**T6. Board page, first version**
- Description: new dashboard page "Board" with two sections, Tickets and MRs (My MRs, Reviewing). Rows show id, title, Linear status pill, MR state; click opens the URL in the browser. Menu bar value becomes "tickets · MRs".
- Acceptance: page matches the counts in the menu; empty and error states visible; works light and dark.
- Verify: `bash scripts/build.sh && open build/ModelDeck.app`; screenshot with synthetic data in `docs/`.
- Depends on: T3, T5. Files: `Sources/ModelDeck/BoardView.swift`, `Dashboard.swift`, `English.json`.

**Checkpoint 2:** both sources live, page and menu agree, facts match the Python collector for the same moment.

### Phase 3: verdicts and next action

**T7. Port MR step and merge-state rules (Core)**
- Description: Swift `MRSteps.step`, `mergeState`, `stepFromLabel`, owed threads; port `tests/test_steps.py` cases one to one.
- Acceptance: all ported cases pass; the 8 skill eval scenarios that concern facts (no-approval-required, own-mr-approval, resolve-and-merge, merged-not-applied) have a matching test.
- Verify: `swift test --filter MRStepsTests`.
- Depends on: T4. Files: `Sources/ModelDeckCore/MRSteps.swift`, `Tests/ModelDeckCoreTests/MRStepsTests.swift`.

**T8. BoardBuilder: link tickets to MRs, verdict and owner**
- Description: link by ticket id in MR title or branch (`IN-1234`) and Linear attachments; ticket inherits its MR's step. Verdict from facts: mergeable own MR = close; step owed by user = notyet; waiting on reviewer/author = hold with the person's name; never "waiting on you to approve" your own MR; no approval required is not approved. Sort Do, then Waiting.
- Acceptance: every row has a next action and an owner; rows without one are dropped and counted in a debug log; rules covered by tests.
- Verify: `swift test --filter BoardBuilderTests`.
- Depends on: T1, T7. Files: `Sources/ModelDeckCore/BoardBuilder.swift`, tests.

**T9. Show verdicts in UI and "act now" in menu bar**
- Description: stripe colour and label per verdict, next action line, owner; menu bar value shows act-now count (option: total). Each row offers "Open", and "Copy prompt" that copies the step prompt (same text as `mr_steps.step_prompt`) for Claude Code.
- Acceptance: colours match the skill template legend; copy puts the exact prompt on the pasteboard; nothing is posted.
- Verify: build and open app; manual check against a fresh skill-generated board on the same data.
- Depends on: T6, T8. Files: `BoardView.swift`, `MenuBarSummary.swift`, `English.json`.

**Checkpoint 3:** side by side with the skill board for one morning; differences listed and either fixed or accepted as "model judgment, not ported".

### Phase 4: polish and release

**T10. Refresh, staleness and failure handling**
- Description: manual refresh button, configurable interval (1 to 60 min), stale marker after 2 intervals, backoff on HTTP 429/401, partial board when one source fails (labelled "unknown").
- Verify: `swift test`; manual: revoke key, disconnect network.
- Depends on: T9. Files: `DeckStore.swift`, `BoardView.swift`, `SettingsView.swift`.

**T11. Localization, docs, version**
- Description: Italian and English strings, README section, CHANGELOG entry, VERSION 0.8.0 in `VERSION` and `project.yml`, synthetic screenshot.
- Verify: `python3 scripts/check-localization.py`; `swift test`; `bash scripts/build.sh`; `xcodegen generate && xcodebuild -scheme ModelDeck build` if Xcode project is kept in sync.
- Depends on: T10.

**Checkpoint 4:** full build from clean, all tests green, README states that the board reads Linear and GitLab (the README now promises "no telemetry", the network calls must be named).

## Decided

- 2026-10-31: board ships in the public app, OFF by default (option A). No PP hosts or paths in code; user enters them in Settings. README must describe the new network requests.

## Open decisions (recommendation in bold)

1. **Port logic to Swift vs. shell out to the Python scripts.** Recommend **port**: the rules are about 100 lines of pure code, the app has no dependencies and must not need Python or the skills folder. Keep the Python as the reference and copy its tests. Cost: two copies to keep in sync; mitigate with shared JSON fixtures.
2. **Linear auth.** Recommend **personal API key in Keychain** (existing `DeckKeychain`). OAuth needs a registered app and a callback; the MCP token is not reachable from the app.
3. **GitLab auth.** Recommend **reuse `glab` via `glab api`** (already authenticated, matches the skill, no token copy). Fallback later: PAT in Keychain plus `URLSession` if glab is missing.
4. **Native SwiftUI vs. WKWebView with `template.html`.** Recommend **native SwiftUI**: fits the app's look, theme and localization; the template's buttons depend on Lavish and the agent, which the app does not have. WKWebView would only be faster for a read-only copy.
5. **Verdict and next-action text.** The skill uses a model for headlines and "next". Recommend **facts-only verdicts in the app** plus "Copy prompt" to hand off to Claude Code. No LLM inside ModelDeck (fits the app's "no model inference requests" promise).
6. **Product fit.** ModelDeck is a public repo (upstream `tommasinigiovanni/ModelDeck`, fork `alandomio/Bldg30`) about local models and quotas. Recommend **an off-by-default feature, or a personal fork only**; Peter Park host names, project paths (`peter-park/...`) and `ships.json` must not be hard-coded. Decide before T6.
7. **Linear ticket filter.** Skill uses states In Review, Staging, To Do. Recommend **configurable list, default those three**.

## Risks

- Rate limits: one MR costs 4 GitLab calls; 30 MRs every 5 minutes is fine, every minute is not. Default 5 min, cap concurrency.
- Linear state names are team specific; filter on state type where possible.
- The README promises no network beyond local and quota readers; adding Linear and GitLab changes that promise and must be documented.
