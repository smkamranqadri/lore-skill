#!/usr/bin/env bash
# lore 2.0 read tracking tests (lore_reads.py). Hand-written fixtures, fictional paths, no real home.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fx="$repo_root/tests/fixtures/reads"

export HOME=/home/fixture-user
store=/home/fixture-user/.agents/lore

fail() { echo "FAIL: $*" >&2; exit 1; }

# check <fmt> <transcript> <store> <expected dict as JSON>
check() {
  local fmt="$1" tr="$2" st="$3" want="$4" got
  got="$(python3 -I - "$repo_root/skills/lore/scripts" "$fmt" "$tr" "$st" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import lore_reads
print(json.dumps(lore_reads.reads(*sys.argv[2:5]), sort_keys=True))
PY
)"
  [[ "$got" == "$want" ]] || fail "$fmt $(basename "$tr"): got $got, wanted $want"
}
sup() {
  local got
  got="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import lore_reads; print(lore_reads.supported(sys.argv[2]))' "$repo_root/skills/lore/scripts" "$1")"
  [[ "$got" == "$2" ]] || fail "supported($1): got $got, wanted $2"
}

check claude  "$fx/claude.jsonl"  "$store" '{"gotchas/web.md": 2, "how-i-work/verification.md": 2, "how-i-work/workflow.md": 2, "tools.md": 3}'
check codex   "$fx/codex.jsonl"   "$store" '{"how-i-work/verification.md": 2, "tools.md": 1}'
check agy     "$fx/agy.jsonl"     "$store" '{"gotchas/web.md": 1, "how-i-work/verification.md": 2, "tools.md": 1}'
check generic "$fx/generic.jsonl" "$store" '{"gotchas/web.md": 1, "how-i-work/verification.md": 2, "tools.md": 1}'

# a trailing slash and a ~ store root name the same store
check claude "$fx/claude.jsonl" "$store/" '{"gotchas/web.md": 2, "how-i-work/verification.md": 2, "how-i-work/workflow.md": 2, "tools.md": 3}'
check claude "$fx/claude.jsonl" '~/.agents/lore' '{"gotchas/web.md": 2, "how-i-work/verification.md": 2, "how-i-work/workflow.md": 2, "tools.md": 3}'
# a different store sees none of it
check claude "$fx/claude.jsonl" /home/fixture-user/.agents/other '{}'

# missing, empty, unreadable and unsupported input return {}
check claude "$fx/missing.jsonl" "$store" '{}'
check claude "$fx/empty.jsonl" "$store" '{}'
check claude "$fx" "$store" '{}'
check bogus "$fx/claude.jsonl" "$store" '{}'

# shell, Codex JS, malformed-record and symlink cases (tables in tests/fixtures/reads)
python3 -I "$fx/run_cases.py" "$repo_root/skills/lore/scripts" "$fx" "$store" || fail "case tables, see above"

sup claude True; sup codex True; sup agy True; sup generic True
sup bogus False; sup "" False

echo "reads tests passed"
