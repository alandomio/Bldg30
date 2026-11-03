# Command lifecycle: `commands.jsonl`

ShipDeck (the app) and firstmate's click bridge share one append-only log of commands. A command is one button click in the Command Bridge.

**File:** `~/Library/Application Support/ModelDeck/companion/commands.jsonl`, next to the `inbox/` folder (it is always `<inbox folder>/../commands.jsonl`). UTF-8, one JSON object per line, ending in `\n`. Never rewrite or delete lines; only append.

## Line format

```json
{"id":"7f3c...","action_id":"in2566-pgclient.opt-1","target":"in2566-pgclient","state":"queued","at":"2026-11-03T08:00:00.123Z","note":null,"label":"retry the two CI jobs"}
```

| Field | Meaning |
|---|---|
| `id` | The click id. Same value as `idempotency_key` in the inbox note `<epoch>-<id>.json`. |
| `action_id` | The action of the click (`<id>.opt-1`, `<ref>.add-context`, ...). Copy it from the note. |
| `target` | The card the click came from (decision id, MR ref, ticket id). Copy it from the note. |
| `state` | `queued`, `picked_up`, `done` or `failed`. |
| `at` | When this transition happened, ISO 8601 UTC. |
| `note` | Optional text shown on the card and in History, for example the result or the reason for a failure. |
| `label` | Optional, on the `queued` line only: the button text. |

## Who writes what

- **The app** writes `queued` when it files the inbox note. The queued line is appended before the note is written, so a later line for the same `id` always follows it. If the note cannot be written, the app appends `failed` with a note.
- **The consumer (click bridge)** writes `picked_up` when it takes a note, and `done` or `failed` when it has a result. Repeat `id`, `action_id` and `target` from the note. A consumer may write `done` or `failed` without a `picked_up` line, but never write a state it has not reached.
- Append each line with one `write()` on a file opened with `O_APPEND`, so lines stay whole.

## State rules

`queued` -> `picked_up` -> `done` | `failed`. Forward only. `done` and `failed` are final.

The app ignores, and counts as ignored: lines that are not valid JSON, unknown `state` values, a line for an `id` that has no `queued` line before it, repeated lines, and any line that moves a command backwards or after `done` or `failed`. The app never decides a state from time: a command with no pickup line stays `queued` however old it is.

## What the app shows

A status pill on the card that issued the latest command (click it to open the history of that card), a status line under each button, and a History tab: newest first, filterable by card, with id, label, target, state and the three timestamps. The app reads the last 1 MB of the file every few seconds.

The older `replies/<key>.json` receipts are no longer read.
