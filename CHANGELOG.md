# Changelog

## 2.0.0-p5a (unreleased)

`lore eval loremaster|canon`: the plan's quality bars, measured by hand against the configured models
before the filing session. Nothing 1.x changes, and no prompt or code of the Loremaster or Canon.

- **A frozen fixture** in `tests/fixtures/eval/`: 60 fictional rules (per rule the expected top-level
  folder and the ids whose rules belong linked, 20 pairs, 4 near-duplicate pairs and 2 contradicting
  pairs) and a Canon store that seeds each lint gate once and nothing else. Its hash is pinned in
  `tests/test-eval.sh`; a changed fixture fails that test and a change needs the owner.
- **`lore eval loremaster`** queues the rules as `lore remember` does and files them through the real
  Loremaster path in batches of 10, then reports the bars as fractions: rules in their expected folder
  (at least 90%), no topic file over lint's oversized limit, expected pairs linked or in one file (at
  least 80%). It writes `spot-check.md`: 15 rules chosen by a fixed sort, the original wording beside
  the filed wording, a blank yes/no for the owner (15 of 15 must be yes). The tool never judges
  meaning.
- **`lore eval canon`** copies the Canon fixture into a temp store, runs Canon once through its model
  as `lore canon --force` does, re-lints, and reports each gate `fixed`, `in Inbox` (a retirement
  waiting for the owner) or `not fixed`.
- Each run builds its own temp store with a local git identity and no hub, never the owner's store:
  `--store2`, and a `--workdir` or `--out` that is or sits inside a store, are refused. `report.md` and
  `report.json` (`--out`, default `./lore-eval-<role>-<UTC stamp>/`) carry the fixture's sha256, the
  role's command line, wall time and an estimated token count (characters over four; the CLIs report
  none). Exit 0: every bar the tool computes is met; 1: one is not; 2: the run failed or did not start
  (a failing or unparseable reply is reported, never retried).
- `SKILL.md` version `2.0.0-p5a`; `tests/test-ui-server.sh` pins that version in its summary check.

## 2.0.0-p4a.1 (unreleased)

Four small fixes after P4a. 1.x behaviour is unchanged except the timer's start line.

- The hub no longer loses a merge's own work. The fetch-rebase ran `git rebase`, which drops merge
  commits, so a file only a local merge commit added was lost locally and on the hub while the
  push still reported success (the "Known limit" in 2.0.0-p4a below: fixed). lore does not replay
  merges: when the local commits to rebase onto the hub include a merge, nothing is rebased, the
  store stays exactly as it was, the push counts as failed and one line names the merge and the
  manual fix: `hub: push FAILED (a local merge <sha7> "<subject>" cannot be rebased onto the hub;
  lore does not replay merges. Merge the hub in yourself, e.g. git -C <store> merge <hub ref>,
  then the next run pushes)`. Merging keeps what only the merge commit added, and the hub is then
  in the store's history, so the next push is a fast-forward. Each run refuses again until the
  owner acts. When the hub has nothing new there is nothing to rebase and the merge pushes as it
  is. Linear history behaves as before; Canon's landing gets the same refusal.
- lore never completes the owner's unfinished git operation. The manual merge above can stop on a
  conflict; the next session end then ran `tidy` and `commit`, which staged the conflict markers,
  finished the merge and let the next push publish them. Every writer that stages, commits or
  rewrites a tracked file (`commit`, `tidy`, recording reads, a Loremaster or Inbox batch, Canon, the
  hub's fetch-rebase, attaching a hub) now first checks for a merge, cherry-pick or revert in
  progress (a multi-pick one also while `.git/sequencer` holds its picks, which is all git keeps
  after the owner has staged a first conflict), a rebase lore did not start, or unmerged index entries. It touches nothing (HEAD, index
  and work tree stay as they are) and says `store: an unfinished git merge is in progress in <store>;
  resolve and commit it, or run git -C <store> merge --abort, then the next run continues`; session
  end logs it, reads and pushes nothing, and counts no failed push. A rebase lore itself started
  is told apart from the owner's by instance, not by its inputs: lore writes a random token in
  `.git/lore-rebase` and, through the sequence editor git runs once its rebase directory exists,
  the same token in `rebase-merge/lore-token`. `git rebase --abort` removes that directory, so a
  rebase the owner starts afterwards, even onto the same target from the same HEAD, has no token
  and is the owner's; anything ambiguous refuses. Recovery of a rebase a hard kill left behind
  happens once, where a writer begins and before it reads the store, looks up an Inbox item or
  builds any content (session end, `store commit|status|index`, `hub set|create`, Loremaster
  batches, `lore inbox accept|reject` and the UI's routes, Canon), so what it writes is built from
  the restored branch and an unreplayed local rule survives. The check at the write itself only
  refuses and writes nothing. A stale mark is cleared when lore's rebase ends and dropped when it
  matches nothing.
- The 1.x timer fires after a late login. `sync-timer install` wrote `OnBootSec=2min`, which counts
  from kernel boot, so a user manager started later never fired it. It now writes
  `OnStartupSec=2min` (counted from the user manager's start); `OnUnitActiveSec` and
  `Persistent=true` are as before. `sync-timer check` reports a unit that still has `OnBootSec` as
  out of date, and `sync-timer install` rewrites it.
- `tests/test-sync.sh` made its `pull` and `push` folders outside its temp folder, so its trap never
  removed them; they are made under it now, as is the fake agent's export folder in
  `tests/test-syncrun.sh`.

## 2.0.0-p4a (unreleased)

lore 2.0, phase 4a: the UI for 2.0.0 (Memory, Graph, Inbox and a read-only Changes) and its local
server. 1.x behaviour is unchanged. Revert (`lore revert` and reverting from Changes) is deferred
to P4b: it was built and reviewed in five rounds, and the last review still found work it could
lose, so this phase ships without it.

- `lore ui [--port N]`: a standard-library server on 127.0.0.1 only (the first free port from 3870
  to 3889), printing one line, `lore ui: http://127.0.0.1:<port>/#t=<token>`, and opening no
  browser. Every response checks the `Host` header first (`127.0.0.1:<port>` or
  `localhost:<port>` only) and carries `nosniff`, `no-referrer` and a `default-src 'self'` CSP; no
  response has a CORS header or sets a cookie, and `OPTIONS` is 405. The JSON API needs the token
  in an `X-Lore-Token` header (constant-time compare); the token lives in memory only and is never
  logged. Read routes (summary, memory, file, graph, inbox, changes, commit) take no lock and write
  nothing; Changes pages are slices of one traversal from HEAD, so a merged history is listed once.
  The write routes (Inbox accept and reject) take the run lock without waiting (busy is 409) and
  call the same functions as `lore inbox`, so the commits are the same; `pushed` is true, false
  (the push failed) or null (no hub). A request's line, headers and body must arrive within 10
  seconds (`LORE_UI_TIMEOUT`), or it is closed unanswered; at most 16 are served at once, a
  connection beyond them closed.
- `ui/`: the UI source, React + Vite + TypeScript + Tailwind + d3-force, with Playwright
  (Chromium) tests; exact versions, lockfile committed, node pinned in `ui/.nvmrc` and `engines`.
  The built bundle ships in `skills/lore/ui/dist/` (no source maps, no external URL). `npm run
  check-dist` rebuilds into a temporary folder and fails, naming each file, when the committed
  bundle differs; CI's new `ui` job runs it and the Playwright tests.
- Known limit, from P1 (reported in P4a, not changed): when the hub has another machine's commits,
  the push's fetch-rebase replays local commits without their merges, so work recorded only by a
  local merge commit (a file the merge itself added) is lost locally and on the hub.

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
