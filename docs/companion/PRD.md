# PRD: ModelDeck as the firstmate companion

Status: accepted (grill with Alan, 2026-11-01). Owner: Alan Domio.

## Problem

Alan works through firstmate, but what needs him is scattered across chat replies, the Lavish action board, Linear and GitLab. On 2026-11-01 alone:

- decisions held for him were spread over 20+ chat messages and old status records;
- the same 10 review requests were re-announced more than 5 times;
- workers sat on a startup prompt for days and nobody saw it.

The Lavish board helps, but it is a page he must open and refresh. ModelDeck already lives in the menu bar, polls quotas, and has a dormant Linear integration (`ModelDeckCore/LinearBoard.swift`).

## Goal

One native place that shows what needs Alan now (decisions, his MRs and reviews, his tickets), each with its next action and a button that asks firstmate to do it. Firstmate keeps every approval rule.

## Users

Alan first. The app must stay generic so any firstmate user can run it.

## Decisions (from the grill)

1. **Generic app, firstmate-owned feed.** ModelDeck contains no company names, project paths or firstmate rules. It reads a local *companion feed* file that firstmate writes. The repo moves to private GitLab soon; the split still holds.
2. **Clicks are inbox notes.** Every button files a structured firstmate inbox note (action, target, exact draft text, idempotency key). Firstmate handles it under its own gates and replies; the app shows the reply. The app never posts, approves or merges by itself.
3. **Firstmate owns the judgment.** The feed carries firstmate's verdict, who moves next, drafts and urgency. A feed script refreshes MRs (glab) and tickets (a personal read-only Linear API key in the macOS Keychain) without an agent turn.
4. **The app polls and reports changes.** The app polls Linear and GitLab and writes deduplicated, batched change events to one firstmate process-event source. Events never use the inbox. A fast "System 1" classifier may replace the fixed event rules later.
5. **Health panel first, MCP server later.** Version 2 shows MCP servers, CLI logins and firstmate monitoring health. The app as its own MCP server is a later option.
6. **One feed, two renderers.** The linear-action-board skill writes the feed; the Lavish page and ModelDeck both render it. The Lavish page may retire later.
7. **Quiet by default.** The menu bar badge shows the count of decisions waiting. macOS notifications fire only for items firstmate marks urgent.
8. **Order.** Version 1: decisions, my MRs and reviews, my tickets. Version 2: health panel, workers panel (flags workers stuck on a prompt or quiet too long, with the exact prompt text).

## Out of scope

- The app acting directly on GitLab or Linear.
- The app calling firstmate scripts directly.
- Notifications for every change.
- An MCP server in the app (version 1 and 2).

## Success measures

- Alan answers decisions from the app instead of scrolling chat (self-reported after 2 weeks).
- No repeat notification for an unchanged item (event fingerprints).
- A worker stuck on a prompt shows in the app within 5 minutes (version 2).

## Risks

- **Feed drift between Lavish and the app.** Mitigation: one feed schema, versioned, validated on both sides.
- **Event floods.** Mitigation: fingerprints, batching, and a cap per window.
- **Secrets.** The Linear key and GitLab token stay in the Keychain; the feed holds no tokens.
- **Stale feed.** The feed carries `generated_at`; the app shows its age and greys out when stale.
