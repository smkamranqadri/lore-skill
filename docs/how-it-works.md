# How lore works

lore has three jobs: learn from your sessions, keep a small and reviewed set of rules, and put
those rules in front of every agent. Everything lives in plain files under `~/.agents/memory/`.

![How lore works](assets/how-it-works.svg)

## Learn

1. **A hook queues the session.** Each agent runs `lore-hook.sh` when a session ends (Claude
   Code, Codex) or when a turn finishes (Command Code, agy). The hook copies the agent's small
   JSON payload into `queue/`, starts the harvester fully detached, and exits in milliseconds.
2. **The harvester reads only your words.** It opens the session transcript at the point it last
   stopped and keeps only the messages you typed: no tool output, no injected context, no agent
   replies. For agents that report every turn, it waits until the session has been quiet for ten
   minutes, so one session is read once.
3. **A regex decides whether to bother.** Messages that look like a correction or a preference
   ("no", "don't", "always", "instead", "remember:") go on; everything else stops here, with no
   model call. Secret-looking strings are redacted first.
4. **A cheap model writes candidate rules.** The first available extractor CLI turns the hits
   into one-line rules, each with a topic. Facts that hold for one project only are written to
   `notices` as belonging in that project's own memory, never stored as rules.

A sweep at the start of each session picks up anything the hooks missed (a crash, or Codex before
you trusted its hooks). The first sweep only sets a starting point, so your old history is never
mass-processed.

## Keep

- **Candidate to rule.** A candidate becomes a rule once it is seen in separate sessions on two
  different days, or at once when you say "remember:", "always" or "never". One long session that
  runs past midnight still counts once.
- **Daily review.** The first harvest of each day asks a stronger model (Claude Opus, then Codex
  at high effort, by default) to review what is new: merge near-duplicates, rewrite
  contradictions into scoped rules, and reject noise or project facts. It may only touch the
  rules it was shown, and every decision is written to `review.log` with its reason.
- **Decay.** Candidates unseen for 28 days are deleted. Rules lose a little confidence for every
  month they go unseen and are removed when they fall too low. Pinned rules never decay.
- **Limits.** At most 25 rules per topic; "drop that" deletes a rule and blocklists it so it is
  never learned again.

## Use

The index (`INDEX.md`) is regenerated after every change and capped at about 1,500 tokens:

- the strongest rules in full (pinned ones first),
- the rules learned in the last week, under **New**, so you can veto them,
- one "read when" line per topic file, so an agent opens a topic only when the task needs it.

lore delivers it into each agent's global instruction file, between `<!-- lore:index start -->`
and `<!-- lore:index end -->`. Claude Code and Command Code import the file; Codex and agy get a
copy that is refreshed whenever the index changes.

## Several machines

With a hub configured, the index tells the agent when a sync is due (local changes, or a day
since the last sync). The agent moves the memory files to and from the hub over its MCP, and lore
merges them: entries are matched by id, the newest evidence wins, removals travel as tombstones,
and the result is the same whichever machine syncs first. See [Configuration](configuration.md).

## Files

```text
~/.agents/memory/
  INDEX.md            what every agent loads
  <topic>.md          the rules for one topic, one per line
  candidates.md       rules waiting for a second day
  profile.md          who you are, written by you
  blocklist           rules you dropped
  tombstones          removals, so a sync does not bring them back
  queue/              sessions waiting to be read
  harvest.log, review.log, notices
```

Each rule line keeps valid Command Code taste syntax up to its confidence, followed by an HTML
comment with what lore needs (id, dates seen, counts, flags, a short quote of your words).
