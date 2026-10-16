#!/usr/bin/env bash
# lore v1 taste harvest tests (lore.py learn-taste). Temporary HOME; a fake extractor.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lore="$repo_root/skills/lore/scripts/lore.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset LORE_STORE LORE_HARVEST 2>/dev/null || true
log="$tmp/log"; store="$HOME/.agents/memory"; calls="$tmp/calls"

fail() { echo "FAIL: $*" >&2; echo "--- last output ---" >&2; cat "$log" >&2 || true; exit 1; }
ok()   { "$@" >"$log" 2>&1 || fail "$* exited non-zero"; }
deny_msg() {
  local d="$1" want="$2"; shift 2
  if "$@" >"$log" 2>&1; then fail "$d"; fi
  grep -q -- "$want" "$log" || fail "$d (wanted '$want')"
}
L() { python3 "$lore" "$@"; }
ncalls() { [[ -f "$calls" ]] && wc -l < "$calls" | tr -d ' ' || echo 0; }

cat > "$tmp/fake-extract.sh" <<'EOF'
#!/usr/bin/env bash
echo call >> "$FAKE_CALLS"; cp "$LORE_PROMPT_FILE" "$FAKE_CALLS.last-prompt"
[[ -n "${FAKE_FAIL:-}" ]] && { echo "down" >&2; exit 1; }
p="$(cat "$LORE_PROMPT_FILE")"; items=()
grep -q 'pnpm' <<<"$p" && items+=('{"rule":"Use pnpm, not npm, in node projects","category":"tools","quote":"pnpm","explicit":false,"scope":"global","contradicts":null}')
grep -q 'bench migrate' <<<"$p" && items+=('{"rule":"Run bench migrate after restarting the backend","category":"tools","quote":"bench","explicit":false,"scope":"project","contradicts":null}')
grep -q 'toggle' <<<"$p" && items+=('{"rule":"Prefer toggle switches over checkboxes","category":"ui","quote":"toggles","explicit":false,"scope":"global","contradicts":null}')
(IFS=,; echo "[${items[*]}]")
EOF
chmod +x "$tmp/fake-extract.sh"
export LORE_EXTRACT_CMD="bash '$tmp/fake-extract.sh'" FAKE_CALLS="$calls" LORE_REVIEW_CMD="echo '[]'"

app="$HOME/work/app/.commandcode/taste"; mkdir -p "$app/taste" "$HOME/.commandcode/taste/cli" \
  "$HOME/work/app/node_modules/dep/.commandcode/taste" "$HOME/work/.hidden/x/.commandcode/taste"
printf '# Taste\nSee [taste/taste.md](taste/taste.md)\n' > "$app/taste.md"
printf '# Taste\n- Uses pnpm instead of npm. Confidence: 0.80\n- Runs bench migrate after docker restart. Confidence: 0.70\n' > "$app/taste/taste.md"
printf '# CLI\n- Prefers toggle switches over checkboxes. Confidence: 0.60\n' > "$HOME/.commandcode/taste/cli/taste.md"
printf '# Taste\n- From a dependency, never read. Confidence: 0.90\n' > "$HOME/work/app/node_modules/dep/.commandcode/taste/taste.md"
printf '# Taste\n- From a hidden folder, never read. Confidence: 0.90\n' > "$HOME/work/.hidden/x/.commandcode/taste/taste.md"
ok L --today 2026-10-16 init
printf 'taste_roots: %s,%s\n' "$HOME/.commandcode/taste" "$HOME/work" >> "$store/config"

# 1. Finds every taste file under the roots, skips dependencies and hidden folders, and sends the
#    new entries, labelled by project or global, to the extractor once.
ok L --today 2026-10-16 learn-taste
grep -q '^taste: 3 file(s), 3 new or strengthened entries$' "$log" || fail "wrong files or entries: $(head -1 "$log")"
[[ "$(ncalls)" == 1 ]] || fail "extractor called $(ncalls) times"
grep -q '\[project app, confidence 0.80\] Uses pnpm instead of npm' "$calls.last-prompt" || fail "project entry not labelled"
grep -q '\[global, confidence 0.60\] Prefers toggle switches' "$calls.last-prompt" || fail "global entry not labelled"
grep -q 'never read' "$calls.last-prompt" && fail "a dependency or hidden folder was read"
grep -q 'Return ONLY a JSON array' "$calls.last-prompt" || fail "the prompt lost its output instruction"

# 2. Global items become candidates; project facts are noted, not stored.
grep -q 'Use pnpm, not npm, in node projects\. Confidence: 0\.30 .*cat=tools' "$store/candidates.md" || fail "pnpm not a candidate"
grep -q 'bench migrate' "$store/candidates.md" && fail "a project fact became a candidate"
grep -q "project fact, belongs in that project's KIS: Run bench migrate" "$store/notices" || fail "project fact not noted"

# 3. Unchanged entries are not new sightings: a second run makes no call.
ok L --today 2026-10-17 learn-taste
grep -q '^taste: 3 file(s), 0 new or strengthened entries$' "$log" || fail "unchanged entries counted again"
[[ "$(ncalls)" == 1 ]] || fail "extractor called for unchanged taste"

# 4. A raised confidence is a new sighting; on a new day it promotes the candidate.
sed -i 's/Uses pnpm instead of npm. Confidence: 0.80/Uses pnpm instead of npm. Confidence: 0.90/' "$app/taste/taste.md"
ok L --today 2026-10-17 learn-taste
grep -q '1 new or strengthened entry$' "$log" || fail "a raised confidence was not seen"
grep -q 'Use pnpm, not npm, in node projects\. Confidence: 0\.60 ' "$store/tools.md" || fail "a second-day taste sighting did not promote"

# 5. A failed extraction records nothing, so the next run sees the same entries.
printf -- '- Prefers dark mode everywhere. Confidence: 0.70\n' >> "$HOME/.commandcode/taste/cli/taste.md"
deny_msg "a failed harvest exited zero" "unfinished entries not recorded" env FAKE_FAIL=1 python3 "$lore" --today 2026-10-18 learn-taste
ok L --today 2026-10-18 learn-taste
grep -q '1 new or strengthened entry$' "$log" || fail "entries from a failed run were marked as seen"

# 6. --root limits the search.
ok L --today 2026-10-18 learn-taste --root "$HOME/.commandcode/taste"
grep -q '^taste: 1 file(s), ' "$log" || fail "--root did not limit the search"

echo "test-taste: all checks passed"
