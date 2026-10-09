#!/usr/bin/env bash
# The files backend of lore: the mechanics of the store. The prose that says when to run these
# lives in ../backends/files.md and ../SKILL.md; this script is the mechanical half.
set -euo pipefail

store="${LORE_STORE:-${HOME}/.agents/memory}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
lore_dir="$(cd "$script_dir/.." && pwd -P)"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  lore-store.sh [--store <dir>] <command> [args]

Commands:
  config [backend|space|store|mapping]  print the resolved backend, space or mapping file
  init                                  create the store and its starter notes (never overwrites)
  list                                  list note names, one per line
  read <note>                           print a note
  sha <note>                            print a note's sha256 (fold's read-back guard)
  create <note> [--title <title>]       create an empty note
  add-thought <note> <text>             append a dated thought under "## Thoughts"
  bump-rule <note> <match>              raise the (xN) marker on the one rule matching <match>
  fold-done <note> --confirm-sha <sha>  delete a folded note's thoughts

Options:
  --store <dir>   Store directory. Defaults to $HOME/.agents/memory (or $LORE_STORE).
  -h, --help      Show this help.
USAGE
}

# --store is accepted anywhere on the command line.
argv=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store) [[ $# -ge 2 ]] || die "--store requires a path"; store="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) argv+=("$1"); shift ;;
  esac
done
set -- ${argv[@]+"${argv[@]}"}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then usage; exit 2; fi
shift

require_store() { [[ -d "$store" ]] || die "store not found: $store (run: lore-store.sh init)"; }

safe_note() {
  case "$1" in
    "") die "missing note name" ;;
    /*|*..*) die "invalid note name: $1" ;;
  esac
}

require_note() {
  safe_note "$1"
  [[ -f "$store/$1" ]] || die "note not found: $1"
}

date_today() { date +%F; }

file_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# config_value <key>: the value of "key: value" in <store>/config, trimmed, empty when absent.
config_value() {
  local key="$1" line value=""
  if [[ -f "$store/config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ "$line" == "$key:"* ]] || continue
      value="${line#"$key:"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      break
    done < "$store/config"
  fi
  printf '%s' "$value"
}

# write_if_absent <relative-path>   (content on stdin): creates the file only when absent, so
# init is safe to run at every load and never overwrites an edited note.
write_if_absent() {
  local rel="$1"
  [[ -e "$store/$rel" ]] && return 0
  mkdir -p "$(dirname "$store/$rel")"
  cat > "$store/$rel"
  created+=("$rel")
}

case "$cmd" in
  config)
    key="${1:-}"
    backend="$(config_value backend)"
    [[ -n "$backend" ]] || backend="files"
    space="$(config_value space)"
    mapping="$lore_dir/backends/$backend.md"
    case "$key" in
      "")
        printf 'backend: %s\n' "$backend"
        if [[ -n "$space" ]]; then printf 'space: %s\n' "$space"; fi
        ;;
      backend) printf '%s\n' "$backend" ;;
      space) printf '%s\n' "$space" ;;
      store) printf '%s\n' "$store" ;;
      mapping)
        [[ -f "$mapping" ]] || die "no mapping file for backend: $backend (looked at $mapping)"
        printf '%s\n' "$mapping"
        ;;
      *) die "unknown config key: $key" ;;
    esac
    ;;

  init)
    created=()
    write_if_absent config <<'EOF'
backend: files
EOF
    write_if_absent start-here.md <<'EOF'
# Start here

Lore is the user's memory across projects: preferences, core rules, gotchas per stack, the user
profile and references. What is true in one project only belongs in that project's own memory
(KIS), never here.

Read at every session start:

- `preferences.md` — how the user wants work done.
- `core-rules.md` — the rules that cost the most when broken.

Read when they apply, and nothing else:

- `gotchas/<stack>.md` — when the work touches that stack.
- `coordinating.md` — when you brief, run or merge other agents.
EOF
    write_if_absent preferences.md <<'EOF'
# Preferences

1. Short and direct: report what changed and what was proved, without preamble or ceremony.
2. Keep prose in the user's own voice; no formal report tone.
3. Prefer the plain, explicit solution over the clever one.
EOF
    write_if_absent core-rules.md <<'EOF'
# Core rules

The rules that have cost the most when broken. Follow them without being reminded.

1. Check the real state behind every claim: a "done", another agent's report, a status line, your own memory. Hit the route, list the path, read the latest message. (×2)
2. Mutation-check every guard: break it, watch its test fail, then restore the original.
3. Look at the rendered result after every UI change, even with tests green.
4. Send a long job's full output to a log file and read the file; never pipe it through `tail`.
5. Never print any part of a secrets file: check secrets by name, length or hash only.
6. Write State so it is true after the action you are about to take.
EOF
    write_if_absent coordinating.md <<'EOF'
# Coordinating parallel agents

- One brief per agent, self-contained: scope, out of scope, proof, and the files it owns.
- One worktree or directory per agent; never let two agents edit one tree.
- Judge an agent by the artifact, not by its report.
EOF
    write_if_absent profile.md <<'EOF'
# Profile

Who the user is. Add a fact only after the user confirms it in words, as for preferences.
EOF
    write_if_absent references.md <<'EOF'
# References

Where a repo, tool or service lives, so it can be found without searching. A reference names the
thing and where to find it, never a secret, address or value.
EOF
    write_if_absent gotchas/shell-macos-claude-code.md <<'EOF'
# Gotchas: shell, macOS and Claude Code

- In zsh, write commands out: an unquoted variable is not word-split, and an unmatched glob aborts the command.
- Format only the files you changed; never pass a directory to a formatter, and read what a lint script does before running it (it may be `eslint --fix`).
EOF
    if [[ ${#created[@]} -eq 0 ]]; then
      echo "Store current: $store"
    else
      printf 'Created %s\n' "${created[@]}"
    fi
    ;;

  list)
    require_store
    ( cd "$store" && { find . -type f -name '*.md' | sed 's|^\./||' | grep -v '^pending\.md$' || true; } | sort )
    ;;

  read)
    rel="${1:-}"; require_note "$rel"
    cat "$store/$rel"
    ;;

  sha)
    rel="${1:-}"; require_note "$rel"
    file_sha "$store/$rel"
    ;;

  create)
    require_store
    rel="${1:-}"; shift || true
    title=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) [[ $# -ge 2 ]] || die "--title requires text"; title="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    safe_note "$rel"
    [[ -e "$store/$rel" ]] && die "note already exists: $rel"
    [[ -n "$title" ]] || title="$(basename "$rel" .md)"
    mkdir -p "$(dirname "$store/$rel")"
    printf '# %s\n' "$title" > "$store/$rel"
    echo "Created $rel"
    ;;

  add-thought)
    require_store
    rel="${1:-}"; text="${2:-}"
    require_note "$rel"
    [[ -n "${text//[[:space:]]/}" ]] || die "thought text is required"
    [[ "$text" != *$'\n'* ]] || die "a thought is one line; split it or fold first"
    if grep -qx '## Thoughts' "$store/$rel"; then
      [[ -n "$(tail -c 1 "$store/$rel")" ]] && printf '\n' >> "$store/$rel"
    else
      [[ -s "$store/$rel" ]] && printf '\n' >> "$store/$rel"
      printf '## Thoughts\n\n' >> "$store/$rel"
    fi
    printf -- '- %s: %s\n' "$(date_today)" "$text" >> "$store/$rel"
    echo "Thought added to $rel"
    ;;

  bump-rule)
    require_store
    rel="${1:-}"; match="${2:-}"
    require_note "$rel"
    [[ -n "$match" ]] || die "match text is required"
    # Only lines above "## Thoughts" are rules; a bulleted thought is never a rule.
    thoughts_ln="$(grep -nE '^## Thoughts[[:space:]]*$' "$store/$rel" | head -n1 | cut -d: -f1 || true)"
    hits=()
    while IFS= read -r h; do
      hit_ln="${h%%:*}"
      if [[ -n "$thoughts_ln" && "$hit_ln" -ge "$thoughts_ln" ]]; then continue; fi
      hits+=("$h")
    done < <(grep -nE '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]+' "$store/$rel" | grep -F -- "$match" || true)
    [[ ${#hits[@]} -gt 0 ]] || die "no rule matches: $match"
    [[ ${#hits[@]} -eq 1 ]] || die "${#hits[@]} rules match '$match'; give more of the rule"
    local_ln="${hits[0]%%:*}"
    line="${hits[0]#*:}"
    if [[ "$line" =~ \(×([0-9]+)\)[[:space:]]*$ ]]; then
      n=$(( ${BASH_REMATCH[1]} + 1 ))
      newline="${line%\(×*}(×$n)"
    else
      n=2
      newline="$line (×2)"
    fi
    awk -v ln="$local_ln" -v repl="$newline" 'NR==ln{print repl; next}{print}' "$store/$rel" > "$store/$rel.tmp"
    mv "$store/$rel.tmp" "$store/$rel"
    echo "Bumped $rel line $local_ln to ×$n"
    ;;

  fold-done)
    require_store
    rel="${1:-}"; shift || true
    confirm=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --confirm-sha) [[ $# -ge 2 ]] || die "--confirm-sha requires a hash"; confirm="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    require_note "$rel"
    head_ln="$(grep -nE '^## Thoughts[[:space:]]*$' "$store/$rel" | head -n1 | cut -d: -f1 || true)"
    [[ -n "$head_ln" ]] || die "no thoughts to delete in $rel"
    thoughts="$(tail -n +"$((head_ln+1))" "$store/$rel" | grep -cE '^[[:space:]]*-[[:space:]]' || true)"
    [[ "$thoughts" -gt 0 ]] || die "no thoughts to delete in $rel"
    [[ -n "$confirm" ]] || die "refusing to delete thoughts without --confirm-sha <sha> from a fresh read"
    now="$(file_sha "$store/$rel")"
    [[ "$now" == "$confirm" ]] || die "note changed since you read it (sha $now); read it back and retry"
    awk -v start="$head_ln" '
      NR < start { print; next }
      NR == start { skip=1; next }
      skip && /^## / { skip=0 }
      skip { next }
      { print }
    ' "$store/$rel" > "$store/$rel.tmp"
    # Remove the blank lines the deleted section left behind.
    awk '{ a[NR]=$0 } END { n=NR; while (n>0 && a[n] ~ /^[[:space:]]*$/) n--; for (i=1;i<=n;i++) print a[i] }' \
      "$store/$rel.tmp" > "$store/$rel"
    rm -f "$store/$rel.tmp"
    echo "Removed $thoughts thought(s) from $rel"
    ;;

  *)
    usage
    exit 2
    ;;
esac
