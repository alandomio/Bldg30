# Review: obs !101, fix(scheduler): keep the newest plan when two runs overlap [IN-101]

MR: https://gitlab.com/example-group/ops/observability/-/merge_requests/101
Head `abc1234` · target `main` · open · author Sam Example · reviewed 2026-11-03
Size: 14 changed source lines in 1 file (`plan.js`)
Verdict: Not safe to approve as is. Synthetic review report used by the review-draft tests.

## Intent

Synthetic fixture: no real project, person or code.

## Findings

### F1. The overlap fix does not reach the second step (confidence 90)

Synthetic finding.

### F2. Consider: a slow run can still open a second plan (confidence 80)

Synthetic finding.

### F3. The description contradicts the diff (confidence 85)

Synthetic finding.

## Decisions for the human

- F1: ask for the second-step fix in this MR.

## Comment drafts

placement: inline src/scheduler/plan.js:84 @abc1234abc1234abc1234abc1234abc1234abcd (F1)

```text
The freshness rule here does not reach the second step. Please apply the same rule there and add a test.
```

placement: inline src/scheduler/plan.js:80 @abc1234abc1234abc1234abc1234abc1234abcd (F2)

```text
Non-blocking. A slow run can still open a second plan; worth a note in the README.
```

placement: general (F3)

```text
The description says the overlap check is unchanged, but this MR changes it. Please describe both changes.
```

## Routing

Synthetic.
