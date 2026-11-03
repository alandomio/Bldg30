#!/bin/bash
# Clicks every kind of Bridge button in an offscreen window and checks the files written to a throwaway inbox.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-build/ShipDeck.app}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/inbox"
python3 - "$work/feed.json" <<'PY'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({"schema": "companion-feed.v1", "generated_at": now, "producer": "ui-selftest", "warnings": [],
 "decisions": [{"id": "dec-1", "title": "Ship it?", "project": "p", "why_now": "w", "options": [
   {"label": "Ship now", "consequence": "fast", "action_id": "dec-1.opt-1", "outward": False},
   {"label": "Wait", "consequence": "slow", "action_id": "dec-1.opt-2", "outward": False}], "recommendation": "Wait", "links": [], "urgent": False}],
 "mrs": [{"ref": "svc !12", "url": "https://example.com/svc/-/merge_requests/12", "title": "Add retry", "role": "author", "verdict": "notyet", "label": "Fix the threads",
   "next_owner": "you", "pipeline": "failed", "open_threads": 2,
   "drafts": [{"id": "draft", "target": "svc !12", "target_url": "https://example.com/svc/-/merge_requests/12", "text": "Rebased."}],
   "actions": [{"id": "row-mr-svc-12.fix-the-threads", "label": "Fix the threads", "outward": False},
               {"id": "row-mr-svc-12.post-drafted-reply", "label": "Post drafted reply", "outward": True}]}],
 "tickets": [{"identifier": "IN-1", "url": "https://example.com/issue/IN-1", "title": "Retry", "status": "In Review", "finish": {"step": "Merge", "owner": "you"},
   "linked_mrs": ["svc !12"], "actions": [{"id": "row-t-in-1.fix-the-threads", "label": "Fix the threads", "outward": False}]}]}, open(sys.argv[1], "w"))
PY
status=0
"$app/Contents/MacOS/ShipDeck" --ui-selftest --feed "$work/feed.json" --inbox "$work/inbox" --english || status=$?
n=$(grep -c '"state":"queued"' "$work/commands.jsonl" 2>/dev/null || echo 0); k=$(ls "$work"/inbox/*.json | wc -l | tr -d ' ')
if [ "$n" = "$k" ] && [ "$k" -gt 0 ]; then echo "PASS every click wrote a queued line in commands.jsonl ($n)"; else echo "FAIL commands.jsonl has $n queued lines for $k clicks"; status=1; fi
echo "inbox files:"; for f in "$work"/inbox/*.json; do echo "  $(basename "$f")  $(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['action_id'], '->', d['target'], '|', d.get('draft_text',''))" "$f")"; done
exit $status
