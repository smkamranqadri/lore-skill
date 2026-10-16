# Security

## Reporting a problem

Please report security problems privately through GitHub's
[security advisories](https://github.com/smkamranqadri/lore-skill/security/advisories/new),
not in a public issue. Expect a first reply within a week.

## What lore touches

- **Reads:** your own messages in your agents' local session transcripts, and Command Code's
  taste files when you run `learn-taste`.
- **Writes:** `~/.agents/memory/`, the lore block between its markers in each agent's global
  instruction file, and lore's own entries in each agent's hook settings. `setup` backs up every
  file before it changes it.
- **Sends:** the filtered, redacted text of your corrections to the agent CLIs already on your
  machine (for example `codex exec` or `claude -p`), with those CLIs' hooks turned off. lore has
  no server of its own.

## Safeguards

- Secret-looking strings (API keys, tokens, private keys, `password=` values) are redacted
  before any prompt, and a rule that still looks like one is refused.
- Rule categories coming from another machine are validated, and no write may leave the store.
- Hook commands are fixed strings; payloads are written to files and never evaluated.
