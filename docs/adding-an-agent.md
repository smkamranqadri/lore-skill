# Adding an agent

Every agent lore supports is one adapter file in `skills/lore/hosts/<agent>.conf`. Adding one
usually takes an afternoon: the file, a transcript reader if the format is new, and a test.

## The adapter file

```text
# A short note on what was checked, with the agent's version and the date.
name: myagent
home_dir: ~/.myagent                 # if this folder is missing, lore skips the agent
global_file: ~/.myagent/AGENTS.md    # loaded by the agent at every session start
mode: block                          # import (one @path line) or block (a copy of the index)
import: @{index}                     # only for mode: import
max_bytes: 32768                     # optional size cap of the global file

hooks_file: ~/.myagent/settings.json
hooks_format: claude                 # claude (event -> [{hooks: [...]}]) or agy (named hooks)
hook_events: SessionEnd,SessionStart # events lore listens to
turn_events:                         # events that fire every turn (lore then waits for quiet)
transcript_key: transcript_path      # payload field with the transcript path
session_key: session_id              # payload field with the session id
transcript_format: generic           # claude, codex, agy or generic
transcript_glob: ~/.myagent/sessions/*.jsonl

extract: myagent -p --model <cheap-model> < "$LORE_PROMPT_FILE"
review: myagent -p --model <strong-model> < "$LORE_PROMPT_FILE"
```

## What to check on the real agent

1. **The global file.** Which file does it load at every session start, and does it support
   imports? Test with one session: ask it to quote a line you put there.
2. **Hooks.** Which events exist, where they are configured, and what JSON the hook receives on
   stdin. lore needs an end-of-session or per-turn event whose payload names the transcript.
3. **The transcript.** Where it is written and how a user message looks. If it is not one of the
   existing formats, add a branch to `user_text()` in `scripts/lore_capture.py` that returns only
   what the user typed.
4. **Headless mode.** A one-shot command that reads a prompt and prints the answer, and a way to
   pass the prompt (stdin or an argument; mind flags that take the next argument as the prompt).

## Tests

Add a fixture transcript in the agent's real format to `tests/test-capture.sh` and assert that
only the user's words reach the extractor. Run `tests/run.sh`.
