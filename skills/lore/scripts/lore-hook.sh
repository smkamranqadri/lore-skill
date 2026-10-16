#!/usr/bin/env bash
# lore capture hook, run by a host at session end, pre-compact, per-turn stop or session start.
# Usage: lore-hook.sh <host> <event>     (the host's JSON payload arrives on stdin)
#
# It only queues the payload and starts the harvester fully detached, then exits: Codex gives a
# SessionEnd hook three seconds at most, Claude shares 1.5 s across its SessionEnd hooks, and cmd
# and agy block their agent loop on a hook. It never fails the host: every error exits 0.
host="${1:-}"; event="${2:-}"
[[ "${LORE_HARVEST:-}" == 1 ]] && exit 0          # the harvester's own model call: do not recurse
[[ "$host" =~ ^[a-z][a-z0-9-]{0,31}$ && "$event" =~ ^[A-Za-z]{1,32}$ ]] || exit 0

store="${LORE_STORE:-$HOME/.agents/memory}"
[[ -d "$store" ]] || exit 0                       # lore not initialised here: nothing to do
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 0
queue="$store/queue"
mkdir -p "$queue" 2>/dev/null || exit 0

stamp="$(date +%s)-$$-$RANDOM"
tmp="$queue/.in-$stamp"
{ printf '{"lore_host":"%s","lore_event":"%s","lore_queued":%s,"payload":' "$host" "$event" "$(date +%s)"
  payload="$(head -c 65536)"; [[ -n "$payload" ]] && printf '%s' "$payload" || printf 'null'
  printf '}\n'; } > "$tmp" 2>/dev/null && mv "$tmp" "$queue/$stamp.json" 2>/dev/null

[[ "${LORE_HOOK_NO_SPAWN:-}" == 1 ]] && exit 0     # tests: queue only
sweep=""; [[ "$event" == SessionStart ]] && sweep="--sweep"
# A new session leader, so a host tearing down its process group cannot take the harvester with
# it. macOS has no setsid(1); its stock perl does the same.
if command -v setsid >/dev/null 2>&1; then detach=(setsid); else detach=(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV'); fi
LORE_HARVEST=1 nohup "${detach[@]}" python3 "$here/lore.py" --store "$store" harvest --wait $sweep \
  >>"$store/harvest.log" 2>&1 </dev/null &
exit 0
