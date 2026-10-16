# Current

- Branch: `main`, tracking `origin/main` at `https://github.com/smkamranqadri/lore-skill`
  (public). Version: lore 1.0.0. Vendored KIS 0.10.1.
- Task: done. lore 1.0.0 is public (2026-10-16): squashed release commit `90b0f72` plus the README
  pass `72a38cf`, both green in CI; release `v1.0.0`; repo description and topics set. Proof:
  `tests/run.sh` exit 0 locally (11 suites); GitHub Actions success; the README quick start run
  from GitHub into a temporary home installed 1.0.0 and set up Claude and Codex. The 10 original
  commits stay on the local branch `backup/pre-squash-1.0.0`.
- Done before it: lore v1, all phases, `../intent/plan-2026-10-16-lore-v1.md` (proof in its Status).
- Command: `tests/run.sh` (about five minutes here: each Python start costs about 1 s in the agent
  sandbox); `./bootstrap.sh check --source .`.
- Blocker: none.
- Installed on the owner's Linux machine (2026-10-16): skill, memory with a Tartib hub, index and
  hooks in all four agents; host settings backed up first.
- Next: the owner uploads `docs/assets/social-preview.png` in the repo settings; the owner trusts lore's hooks once in Codex (`/hooks`);
  the macOS install; make the test scripts portable to macOS (they use GNU sed, touch, date) so CI
  can add a macOS runner.
