#!/usr/bin/env bash
# One-command install, check and update of the lore skill into a home.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bootstrap.sh [install|check|update] [options]

Commands:
  install  Install the skill into ~/.agents/skills (default).
  check    Report whether the installed skill differs from the source.
  update   Replace the installed skill with the source when they differ (backup kept).

Options:
  --repo <git-url>   Repository to clone as the source. Also LORE_SKILL_REPO.
  --ref <git-ref>    Git ref to install from. Defaults to main. Also LORE_SKILL_REF.
  --source <path>    Local source repo root. Skips the clone.
  --home <dir>       Home directory to install into. Defaults to $HOME.
  --force            install: replace an existing install.
  --no-claude-link   Do not create ~/.claude/commands/lore.
  -h, --help         Show this help.

Examples:
  bootstrap.sh install --repo https://github.com/smkamranqadri/lore-skill.git
  bootstrap.sh check --source ~/Repositores/side-projects/lore-skill
  bootstrap.sh update --source ~/Repositores/side-projects/lore-skill
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

command_name="install"
if [[ $# -gt 0 ]]; then
  case "$1" in install|check|update) command_name="$1"; shift ;; esac
fi

repo_url="${LORE_SKILL_REPO:-}"
repo_ref="${LORE_SKILL_REF:-main}"
source_arg=""
home_dir="${HOME:-}"
force="false"
claude_link="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo requires a git URL"; repo_url="$2"; shift 2 ;;
    --ref) [[ $# -ge 2 ]] || die "--ref requires a git ref"; repo_ref="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || die "--source requires a path"; source_arg="$2"; shift 2 ;;
    --home) [[ $# -ge 2 ]] || die "--home requires a path"; home_dir="$2"; shift 2 ;;
    --force) force="true"; shift ;;
    --no-claude-link) claude_link="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -z "$source_arg" ]]; then
  [[ -n "$repo_url" ]] || die "missing --repo <git-url>, LORE_SKILL_REPO, or --source <path>"
  command -v git >/dev/null 2>&1 || die "git is required when using --repo"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  git clone --depth 1 --branch "$repo_ref" "$repo_url" "$tmp_dir/lore-skill" >/dev/null
  source_arg="$tmp_dir/lore-skill"
fi
[[ -d "$source_arg/skills" ]] || die "source is not a lore-skill repo root: $source_arg"
source_root="$(cd "$source_arg" && pwd -P)"
[[ -n "$home_dir" ]] || die "missing --home <dir> and HOME is unset"
home_dir="$(mkdir -p "$home_dir" && cd "$home_dir" && pwd -P)"

install_args=(--source "$source_root" --home "$home_dir")
[[ "$claude_link" == "false" ]] && install_args+=(--no-claude-link)

# Prints one line per skill: "<name> current|differs|missing"
compare() {
  local src name dest status
  for src in "$source_root"/skills/*/; do
    name="$(basename "$src")"
    dest="$home_dir/.agents/skills/$name"
    if [[ ! -d "$dest" ]]; then
      status="missing"
    elif diff -rq --exclude=__pycache__ --exclude=.DS_Store "$src" "$dest" >/dev/null; then
      status="current"
    else
      status="differs"
    fi
    echo "$name $status"
  done
}

case "$command_name" in
  install)
    args=("${install_args[@]}")
    [[ "$force" == "true" ]] && args+=(--force)
    "$source_root/scripts/install-skill.sh" "${args[@]}"
    ;;
  check)
    rc=0
    while read -r name status; do
      case "$status" in
        current) echo "Already current: $name" ;;
        differs) echo "Update available: $name (installed copy differs from source)"; rc=1 ;;
        missing) echo "Not installed: $name"; rc=1 ;;
      esac
    done < <(compare)
    exit $rc
    ;;
  update)
    while read -r name status; do
      case "$status" in
        current) echo "Already current: $name" ;;
        differs|missing)
          args=(--source "$source_root" --home "$home_dir" --force)
          [[ "$claude_link" == "false" ]] && args+=(--no-claude-link)
          "$source_root/scripts/install-skill.sh" "${args[@]}"
          ;;
      esac
    done < <(compare)
    ;;
esac
