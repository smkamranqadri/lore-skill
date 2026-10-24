# Changelog

## 2.0.0-p3 (unreleased)

lore 2.0, phase 3, Canon runs and wiring (lint and its gates are `lore_lint.py`, stream E).
1.x behaviour is unchanged.

- Session end (`store run`): after the Loremaster's filing, lint runs; when its gates say Canon
  is due, one Canon call gets the findings and the files they name, each rule with its original
  quote. Nothing due means no call (a logged skip). The reply uses the Loremaster's JSON shape
  with Canon's operations only (`reword`, `split`, `merge`, `describe`, `link`, `unlink`, `move`,
  `retire`; never `add`): the whole batch is validated first, then each operation is its own
  commit, `canon: <op> <file>`, and pushed. A rejected, failing or non-JSON reply writes nothing
  and backs off 120 minutes (`lore canon` honours it too; `--force` overrides). Every Canon call
  counts as the day's run, whatever its outcome: a non-urgent finding then waits the interval
  (urgent gates and `lore canon --force` do not). Canon never writes the owner's working tree: it
  validates and commits in its own private checkout (a local clone in `.git/lore/canon`, built
  from HEAD for each run and removed after it), and its commits land like a second machine's: the
  owner's own changes are committed first (staged in a private index, so whatever the owner has
  staged stays staged, and only on the HEAD it began on), then Canon's commits are replayed onto
  them with the hub's merge drivers and the store fast-forwards. A conflict that policy cannot
  settle drops Canon's commits (the owner's side wins; logged, not a failure); a failed or
  rejected run discards the checkout and nothing else. The Inbox items a landing run proposes,
  and where its pending retirements move, are recorded machine-locally before the fast-forward
  and written after it; if writing fails or the run is killed, the next run writes them. A finding whose retirement waits in the Inbox is left
  for the owner, as long as that item still names the rule's file, id and words (a stale one is
  dropped and logged); a retirement the owner rejected holds back the duplicate and contradiction
  findings it answered, as lint saw them (gate, the file-qualified entries and their words), until
  they change: a new near-duplicate, or a copy of a rule in another file, is a new finding. Each contradiction comes with both sides and their original
  quotes, from any file; the files are shown as whole rule records, those over the size cap named
  by id, and only an entry shown with its quote (that file, id and words, followed through the
  batch's moves, splits and merges) can be reworded.
- New operations: `reword` (same meaning, new words; the original quote, the item quote and any
  contradiction flag are kept), `split` (each rule to exactly one part; the old path stays and
  links to the parts), `merge` (a thin file folded into another; links to it are rewritten, the
  file and its sidecar removed). `reword`, `move` and `retire` take an optional `file` for an id
  that is in two files. `unlink` can remove a link whose target is gone. A move, split or merge
  never lands a rule on a file that already holds its id or its words, and carries a pending
  retirement of that rule along, replaying the moves in order (there and back ends where it began). A merge adds the source's reads per machine into the target and
  keeps the later last read.
- The original quote: `add` records it; `supersede` sets it to the new item's words (the person
  restated the rule); `reword`, `move`, `split` and `merge` keep it.
- An accepted retirement moves the rule to `retired/<same path>` with its whole sidecar entry
  (id, quotes, sessions, counts, the date and reason) in `retired/<path>.json` beside it (kept in
  git, never indexed, linted or reconciled away), and settles any contradiction flag raised
  against its words once no other copy of them is a rule. `retired/**/*.json` has its own merge
  driver (`lore-retired`: a union of archived entries by id; two different entries under one id
  are both kept), so two machines retiring rules of one topic both sync; a store made earlier
  adds the line to its `.gitattributes` at its next commit. `retired/` is refused as a layout
  entry. The Loremaster cannot use Canon's operations.
- `lore lint` (findings, a note for a gate that is off, and whether Canon is due; no model, no
  writes), `lore canon [--force]`,
  `lore canon-log [--days N]`.
- Role `canon:` in config, else each host adapter's line (Claude `opus` high, no tools; Codex
  `gpt-6.1-sol` high, read-only; Command Code and agy listed outside the default order
  `canon_models: claude,codex`). `lore check` lists it; `--live` parses and validates the
  Loremaster's and Canon's replies and reports a non-JSON reply as FAILED.
- Role commands resolve to the real executable: a mise shim or a wrapper script running
  `mise x <tool> -- <command>` is replaced by the install it runs (`installs/<tool>/latest/...`,
  or the pinned version), at check and at run time; `lore check` shows the resolved path. An
  adapter whose wrapper cannot be resolved is passed over and named; a config line naming one is
  BROKEN. The 1.x extract, review and sync commands go through the same resolver when they run
  (a wrapper runs its install, an unresolvable one is refused); their adapter choice, overrides
  and `sync_cmd` are as before, and a command naming a final absolute binary runs unchanged.
  Wrapper scripts are read as shell words (a quoted or absolute path to mise, after `exec`, `env`
  or `VAR=value`).

## 2.0.0-p2 (unreleased)

lore 2.0, phase 2, commands and wiring (the Loremaster itself is `lore_master.py`, stream C).
1.x behaviour is unchanged.

- `lore remember "<text>" [--explicit] [--quote Q]`: queues one item on this machine
  (`.git/lore/remember/`); no model call, no commit. A secret-looking text is refused.
- Session end (`store run`): after the reads, a non-empty queue is filed through the Loremaster
  in one model call, committed and pushed. An empty queue makes no call (a logged skip). Items
  leave the queue only when the batch was applied; a rejected reply or a failing or hanging model
  keeps them, logs why, and backs off for the same 120 minutes as a failed sync.
- Role commands: `loremaster:` in config, else each host adapter's line (Claude `sonnet` medium,
  no tools; Codex `gpt-6.1-sol` medium, read-only; Command Code and agy are listed but outside
  the default order `loremaster_models: claude,codex`). Run with an absolute binary, the prompt in
  `$LORE_PROMPT_FILE`, hooks off, and a 300 s timeout that kills the process group.
- `lore inbox list|accept|reject <id>`: acts on what waits for you; an accepted item is its own
  commit and is pushed.
- `lore check [--live]`: shows each role's command; `--live` runs each once with a tiny prompt.

## 2.0.0-p1 (unreleased)

lore 2.0, phase 1: a plain git store with an optional private hub, beside 1.x. Nothing 1.x
changes: its store, index, hooks, Tartib sync and timer keep working.

- `lore store init|status|index|commit`: a git repo at `~/.agents/lore`. Rule files hold only
  `- rule` lines; metadata lives in one sidecar per file under `.lore/meta/`, matched by text. A
  line written by hand is adopted with an id and reported as an unmatched hand edit.
- `INDEX.md` is built by code from `.lore/layout.json`, `core.md` and each sidecar's `read_when`,
  under the budget (default 1,500 tokens). Not delivered to any host yet.
- One commit per change, with a subject that says what changed. A staged secret refuses the
  commit, naming the file and never the match.
- Every git call is headless: no prompt, ssh in batch mode, no signing, no hooks, a timeout.
- `lore hub set|status|create`: an optional private git hub. `set` does a test push and refuses a
  repository `gh` reports as public; `create` uses `gh repo create --private` after a yes. Every
  commit fetches, rebases and pushes: rule files merge by line, sidecars per rule and field, read
  counts per machine, the index is rebuilt, a layout conflict keeps the hub's and saves the local
  one as a proposal. A failed push is retried on the next run and reported after three.
- Session end: after the 1.x harvest and sync-run, the hook records which memory files the
  session read, commits and pushes.
- `setup` creates the 2.0 store, asks for a hub on a terminal (`--hub URL`, `--no-hub`), and
  writes a `~/.local/bin/lore` command; `setup --remove` removes only that command.

## 1.1.0 (2026-10-19)

Hub sync no longer costs tokens in every agent session.

- `lore.py sync-run`: a free gate (local changes, or no sync in a day) that starts one headless
  agent (Codex `gpt-6-luna`, low effort) only when a sync is needed. One lock, one log line per
  check in `sync-log.jsonl`, the last 20 runs' output in `sync-runs/`.
- After a failed run the gate backs off for two hours (`--force` overrides), a run times out after
  5 minutes, and `sync_cmd` in the config replaces the adapter's command for a machine whose CLI
  needs its own invocation.
- Every session end syncs: the capture hook chains `sync-run` after the harvest (free unless the
  memory changed), and each log line records its trigger (`claude:SessionEnd`, `timer`). The
  timer stays as a slow safety net.
- `lore.py sync-log` summarises skips, runs, failures and tokens, to tune the interval.
- `lore.py sync-timer install|remove|check`: a systemd user timer (default every 30 minutes).
- The memory index no longer carries a "sync is due" line.

## 1.0.0 (2026-10-16)

lore becomes one memory for Claude Code, Codex, Command Code and agy that learns on its own.

- Automatic capture: hooks queue finished sessions; a background harvester reads only your
  messages, skips sessions without a correction, and turns corrections into candidate rules with
  a cheap model. Project facts are noted for the project's own memory, never stored.
- Promotion after two separate days or an explicit "remember:", decay of unused rules, at most
  25 rules per topic, and "drop that" to delete and blocklist a rule.
- A daily review by a stronger model that merges, scopes and rejects, with every decision logged.
- A capped index (about 1,500 tokens) delivered into each agent's global instructions.
- `lore.py setup`: one command that finds your agents, shows the plan, backs up and installs;
  `setup --remove` undoes it.
- Optional sync between machines through a notes hub (Tartib), with tombstones and an
  order-independent merge.
- `/lore:learn-taste` harvests Command Code's taste files.
- Secrets are redacted before any prompt, and secret-looking rules are refused.
- Replaces 0.6.0's manual load, fold and backend machinery.
