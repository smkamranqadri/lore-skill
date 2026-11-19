## Eval-only duplicate attributions

For an item you skip because one rule preserves its entire meaning, add a `duplicates` array to
this reply. Each entry must identify its numbered input and either the exact shown rule path and id,
`{"input": 2, "file": "how-i-work/example.md", "rule_id": "12345678"}`, or an earlier input
filed in this same batch, `{"input": 3, "earlier_input": 1}`. Do not claim partial matches or
uncertain matches. These claims are provisional and the owner will judge their meaning.
