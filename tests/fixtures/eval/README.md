# The eval fixture

The answer key for `lore eval loremaster` and `lore eval canon` (lore 2.0, P5a). **Frozen:** it was
written before the Loremaster and Canon prompts were read for the eval, and nothing here is edited
to make a fake or a real model pass. `tests/test-eval.sh` pins its hash; a changed fixture fails
that test, and a change needs the owner.

## `rules.json`

60 fictional rules, one JSON object each: `id`, `text`, `explicit`, `folder` (the expected
top-level path part), `related` (ids whose rules belong linked to this one), and sometimes a
`note` the eval ignores. Everything in it is invented: the tools (Mossdb, Quillbar, Tarnwell,
Harbourlight, Fennec, Pellucid, Brindle, the Cobbler shell), the project (the Marrow API) and the
person (Bramwell). Each rule is one fact in the owner's voice, 8 to 25 words.

| Expected folder | Rules |
|---|---:|
| `how-i-work` | 24 |
| `gotchas` | 21 |
| `safety` | 5 |
| `preferences` | 4 |
| `stack` | 3 |
| `profile.md` | 3 |

The mix follows the taxonomy pass over the owner's real rules (how-i-work about 40%, gotchas
about 35%, safety and preferences about 8% and 6%), with a few `stack` rules because that folder
starts empty and is filled by the filing session. Six rules are `explicit: true`.

**Related pairs.** 20 expected pairs, each listed once, on the side of the lower id. They are the
shapes the taxonomy pass found: two rules about one tool (Quillbar, Fennec, Pellucid,
Harbourlight, the Cobbler shell), two rules about one practice (replies, background jobs, test
fixtures and mutation checks, verifying claims, orchestration), a gotcha next to the stack rule
that uses the tool (`r29` and `r57`), and a stack pair (`r55`, `r56`). The eval counts a pair as
linked when either file's sidecar links reach the other.

**Near-duplicates (4):** `r01`/`r02`, `r07`/`r08`, `r25`/`r26`, `r46`/`r47`, one fact said twice
in different words. **Contradictions (2):** `r15`/`r16` (one question at a time against all in
one message) and `r51`/`r52` (tabs against spaces). The rules are meant to be reused by Canon's
fixture.

## `canon/`

A ready store tree (rule files, `.lore/meta/` sidecars, `.lore/layout.json`, `.lore/config`) that
seeds every lint gate exactly once and nothing else, on the fixed day 2026-10-01 (the eval builds
its temp store with that day, so the ages below never drift):

| Gate | Where |
|---|---|
| contradiction | `how-i-work/questions.md`: the first of two clashing rules carries the Loremaster's flag |
| core-budget | `core.md`: six long core rules, a 420-token budget, two do not fit |
| broken-link | `gotchas/quillbar.md` links to `gotchas/quillbar-legacy.md`, which is gone |
| orphan | `gotchas/harbourlight.md`: no read-when, no incoming link |
| duplicate | `gotchas/mossdb.md`: two rules with 92% of their words in common |
| oversized | `gotchas/tarnwell.md`: 26 rules, the limit is 25 |
| thin | `gotchas/fennec-snapshots.md`: one rule, 30 days old |
| stale | `gotchas/brindle-cache.md`: last read 122 days before the fixed day; the other files carry read data, so the gate is on |

`canon/expect.json` names, per gate, the finding's file and what a fix looks like. The eval
checks before the model runs that lint finds exactly these eight findings; a mismatch is a fixture
(or lint) problem and is reported, not run.

No secrets, no real paths, no real names.
