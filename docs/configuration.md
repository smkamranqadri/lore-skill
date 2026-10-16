# Configuration

lore works with no configuration. Everything below is optional.

## The config file

`~/.agents/memory/config` holds `key: value` lines:

| Key | Default | What it does |
| --- | --- | --- |
| `budget` | `1500` | token cap for `INDEX.md` |
| `extractors` | `codex,claude,cmd,agy` | which agents' CLIs extract rules, tried in order |
| `reviewers` | `claude,codex` | which agents' CLIs run the daily review, tried in order |
| `settle` | `600` | seconds a per-turn session must be quiet before it is read |
| `hub` | (none) | `tartib` to sync several machines |
| `hub_space` | (none) | the hub space that holds the memory notes |
| `taste_roots` | `~/.commandcode/taste,~` | where `learn-taste` looks for taste files |

## Models

Each agent's adapter in `~/.agents/skills/lore/hosts/<agent>.conf` names the exact command,
model and effort it uses:

| Agent | Extract (cheap, per session) | Review (strong, once a day) |
| --- | --- | --- |
| Codex | `gpt-6-astra`, low effort | `gpt-6.1-sol`, high effort |
| Claude Code | `haiku`, low effort | `opus`, high effort |
| Command Code | `z-ai/glm-5.3-flash`, low effort | |
| agy | `Gemini 3.8 Flash (High)` | |

Edit the `extract:` or `review:` line to use another model. The command reads the prompt from
the file in `$LORE_PROMPT_FILE` and must print a JSON array. lore runs it with
`LORE_HARVEST=1`, so its own hooks do not fire.

## A hub for several machines

Without a hub, lore runs fully on one machine. To keep several machines in step:

1. Add to `~/.agents/memory/config`:
   ```text
   hub: tartib
   hub_space: agent-memory
   ```
2. Connect the [Tartib](https://github.com/smkamranqadri/tartib) MCP in your agents.
3. When the index says a sync is due, the agent follows `commands/sync.md` (or run `/lore:sync`).

Each memory file becomes one note titled `lore/<file>`. Other hubs need only the same four steps
(list notes, read a note, write a note, create a note); contributions are welcome.

## Learning from Command Code taste

`/lore:learn-taste` (or `lore.py learn-taste`) reads every `.commandcode/taste/**/taste.md` under
`taste_roots`. Only entries that are new, or whose confidence rose since the last run, count. To
run it nightly:

```text
17 3 * * * python3 ~/.agents/skills/lore/scripts/lore.py learn-taste >> ~/.agents/memory/harvest.log 2>&1
```

## Commands

`python3 ~/.agents/skills/lore/scripts/lore.py <command>`:

| Command | What it does |
| --- | --- |
| `setup [--dry-run] [--yes] [--remove]` | install into every agent found, or take lore out |
| `add --cat <topic> --text "<rule>" [--explicit]` | record a rule by hand |
| `drop <id>` | delete a rule and blocklist it |
| `list [--cat <topic>] [--candidates]` | show what lore knows |
| `pin <id>` | keep a rule in the index for good |
| `describe <topic> --read-when "<when>"` | set the line the index shows for a topic |
| `deliver [--check]` | refresh every agent's copy of the index |
| `hooks install\|remove\|check` | manage the capture hooks |
| `harvest`, `review [--force]` | run capture or the daily review now |
| `import --file <seed.json>` | bulk-import rules (for example from an old notes file) |
| `index` | regenerate the index and print its size |
