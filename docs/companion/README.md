# Companion (version 1)

ModelDeck renders a feed that a companion tool writes. See PRD.md and PLAN.md here for the decisions.

## Setup
Settings, Companion: turn it on, set the feed file (default `~/Library/Application Support/ModelDeck/companion/feed.json`) and the inbox folder. No inbox folder, no buttons. Off by default.
Demo mode shows `CompanionFixture`; `fixture-feed.json` is the same content for manual tests.

## Contract
- `companion-feed.v1`: read from the feed file, strict (unknown verdict, non-https URL, missing field or duplicate id rejects the whole feed). Older than 15 minutes is stale: greyed out, buttons disabled, no notifications.
- `companion-click.v1`: one `<epoch>-<key>.json` per click in the inbox folder, written atomically. Option buttons use `action_id` `decision:<id>:option:<n>` with the label as `draft_text`; draft buttons use `draft:<id>` with the exact text.
- `companion-event.v1`: types, fingerprint and the 5-minute batcher exist in `CompanionEvent.swift`; nothing produces events yet.
- Click status is inferred from files: in the inbox is sent, moved to `handled/` is picked up, a `<name>.reply.json` beside it is done. The producer must follow this.
- The JSON Schema files from the ai-skills worker did not exist yet; the code follows PLAN section 0.

## Deck Officer comments
Settings, Companion, "Commenti a Deck Officer" makes the comment tool available; a switch in the sidebar turns it on and off (off: no boxes anywhere). A comment files a `companion-click.v1` with `action_id` `comment_deck_officer`, `target` `global` or the card/row id, and the text in `draft_text`. The reply is read from `replies/<idempotency_key>.json` (sibling of the inbox folder, `companion-reply.v1`, field `text`) and shown under the comment.

## Not done (next)
Polling Linear and GitLab and writing events (PLAN step 4). Event kinds are fixed in `CompanionEvent.kinds`.
