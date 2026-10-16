# Contributing to lore

Thanks for helping. lore is small on purpose, so the bar is: every change keeps it small, plain
and proven.

## Getting set up

```bash
git clone https://github.com/smkamranqadri/lore-skill.git && cd lore-skill
tests/run.sh
```

Every suite runs in a temporary HOME and never touches your real agents or memory. Tests never
call a real model: they set `LORE_EXTRACT_CMD` and `LORE_REVIEW_CMD` to small fakes.

## What a good pull request looks like

- **One change, with its test.** A fix comes with a test that fails without it.
- **Guards are mutation-checked.** If you add a check (a refusal, a limit, a filter), break it on
  purpose, confirm its test fails, and restore it. Mention it in the PR.
- **Standard library only.** No new dependencies in `skills/lore/`.
- **Keep `SKILL.md` short.** Agents load it on every use; details go in `commands/` or `docs/`.
- **Bump `metadata.version`** in `skills/lore/SKILL.md` and add a line to `CHANGELOG.md` for any
  change that ships.

## Where things live

```text
skills/lore/           what installs into ~/.agents/skills/lore
  SKILL.md             what an agent reads when it uses lore
  commands/            sync, learn-taste, retro
  hosts/<agent>.conf   one adapter per supported agent
  scripts/             lore.py (store, index, delivery, setup), lore_capture.py (hooks, harvest,
                       review, taste), lore_sync.py (hub sync), lore-hook.sh
tests/                 one suite per area, run by tests/run.sh
docs/                  the pages the README links to
kis/                   the project's own memory (plans, decisions, state)
```

## Good first contributions

- [Add an agent](docs/adding-an-agent.md): one `hosts/<agent>.conf` file plus a transcript reader
  if its format is new.
- A second notes hub besides Tartib (see `commands/sync.md` for what a hub needs).
- Better correction detection in `TRIGGER_RE` (`lore_capture.py`), with examples that must and
  must not match.

## Reporting bugs

Open an issue with your OS, the agent and its version, what you expected, and the relevant lines
of `~/.agents/memory/harvest.log`. Please remove anything private first.
