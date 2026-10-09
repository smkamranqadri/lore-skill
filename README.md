# lore-skill

Source repository for **lore**: one memory across projects for any agent (Claude Code, Codex,
Command Code, others). It holds what is true in every project — lessons, preferences, gotchas
per stack, and later the user profile and references. It replaces the agent-lessons skill.

Nothing here is a live install. The installer copies `skills/lore/` to `~/.agents/skills/lore`
and links `~/.claude/commands/lore`, which is where Claude Code, Codex and other hosts look.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/smkamranqadri/lore-skill/main/bootstrap.sh \
  | bash -s -- install --repo https://github.com/smkamranqadri/lore-skill.git
```

From a local clone: `./bootstrap.sh install --source .`. Flags: `--force` to replace an
existing install (a `.tgz` backup is written to `~/.agents/`), `--no-claude-link`, `--home <dir>`
to install somewhere other than `$HOME`.

## Check and update

```bash
./bootstrap.sh check --source .    # exit 0 when the installed skill equals the source
./bootstrap.sh update --source .   # replace it when it differs, backup kept
```

## Use

Claude Code: `/lore:load`, `/lore:retro`, `/lore:fold`. Codex and others: "run the lore load
step" and follow `~/.agents/skills/lore/commands/<name>.md`. The method is in
`skills/lore/SKILL.md`; the backend in use is resolved from `~/.agents/memory/config` and mapped
in `skills/lore/backends/<backend>.md`.

Two backends ship: `files` (the store below, nothing else installed) and `tartib` (the configured
space in Tartib, over its MCP tools). The store is `~/.agents/memory/`, one Markdown file per note.
With no config, or `backend: files`, lore runs entirely on those files.

## Development

See `AGENTS.md`. Tests: `tests/run.sh` (they install into a temporary HOME, never yours).
