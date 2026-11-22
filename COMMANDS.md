# Command lifecycle: `commands.jsonl`

ShipDeck and firstmate's click bridge share one append-only log of commands. A command corresponds to one inbox note.

**File:** `~/Library/Application Support/ModelDeck/companion/commands.jsonl`, next to the `inbox/` folder (it is always `<inbox folder>/../commands.jsonl`). UTF-8, one JSON object per line, ending in `\n`. Never rewrite or delete lines; only append.

## Line format

```json
{"id":"7f3c...","action_id":"in2566-pgclient.opt-1","target":"in2566-pgclient","state":"queued","at":"2026-11-03T08:00:00.123Z","note":null,"label":"retry the two CI jobs"}
```

| Field | Meaning |
|---|---|
| `id` | The click id. Same value as `idempotency_key` in the inbox note `<epoch>-<id>.json`. |
| `action_id` | The action of the click (`<id>.opt-1`, `<ref>.add-context`, ...). Copy it from the note. |
| `target` | The click target (decision id, MR ref, ticket id or `worker:<task>`). Copy it from the note. |
| `state` | `queued`, `picked_up`, `done` or `failed`. |
| `at` | When this transition happened, ISO 8601 UTC. |
| `note` | Optional result or failure reason. A failed command can display its reason on the card. |
| `label` | Optional, on the `queued` line only: the button text. |

## Who writes what

- **The app** requires a configured inbox path before writing. If the path is blank, it reports an error without writing a ledger entry or inbox note. It appends `queued` before writing the note, so a pickup for the same `id` always follows it. If writing the note fails after it was queued, the app attempts to append `failed` with the error reason.
- **The consumer (click bridge)** writes `picked_up` when it files the note for firstmate and `done` or `failed` when it has a result. Repeat `id`, `action_id` and `target` from the click. A consumer may write `done` or `failed` without a `picked_up` line, but never write a state it has not reached. When firstmate moves the note to its handled inbox, the bridge can also log an `acknowledged` receipt. The app ignores that receipt and continues to show the last accepted state.
- Append each line with one `write()` on a file opened with `O_APPEND`, so lines stay whole.

## State rules

`queued` -> `picked_up` -> `done` | `failed`. Forward only. `done` and `failed` are final.

The app ignores, and counts as ignored: lines that are not valid JSON, unknown `state` values, a line for an `id` that has no `queued` line before it, repeated lines, and any line that moves a command backwards or after `done` or `failed`. A command stays `queued` and continues to display its queued status until the ledger records a later state.

## What the app shows

Decision, MR and ticket cards show a status line for the in-flight or most recent command. The decision card has a History disclosure, and MRs and tickets show history in their Details sections. Each history lists the card's commands newest first with their labels, states and available timestamps. The app reads the last 1 MB during its Bridge refresh, which waits 10 seconds between cycles.

The app uses the ledger as its source of command status. [Deck Officer comments](docs/companion/README.md#deck-officer-comments) use reply files.
