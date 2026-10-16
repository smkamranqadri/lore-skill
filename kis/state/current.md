# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (public). Version: lore 1.0.0. Vendored KIS 0.10.1.
- Task: public release prep for 1.0.0 (owner, 2026-10-16): MIT LICENSE, `lore.py setup`
  (dry run, confirmation, backups; `--remove` undoes it), a landing-page README with two SVG
  images, docs pages, CONTRIBUTING, CHANGELOG, SECURITY, a Linux CI workflow, personal details
  scrubbed. Then the unpushed commits are squashed into one 1.0.0 commit, so no personal detail
  reaches public history. The push needs the owner's word.
- Done before it: lore v1, all phases, `../intent/plan-2026-10-16-lore-v1.md` (proof in its Status).
- Command: `tests/run.sh` (about five minutes here: each Python start costs about 1 s in the agent
  sandbox); `./bootstrap.sh check --source .`.
- Blocker: none.
- Installed on the owner's Linux machine (2026-10-16): skill, memory with a Tartib hub, index and
  hooks in all four agents; host settings backed up first.
- Next: push after the owner approves; the owner trusts lore's hooks once in Codex (`/hooks`);
  the macOS install; make the test scripts portable to macOS (they use GNU sed, touch, date) so CI
  can add a macOS runner.
