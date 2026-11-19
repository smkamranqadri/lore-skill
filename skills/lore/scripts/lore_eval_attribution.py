"""Eval-only duplicate claims. Claims are provisional until the owner checks their meaning."""
import json
import re

import lore
import lore_master

PROMPT = __file__.replace('scripts/lore_eval_attribution.py', 'prompts/eval-attribution.md')


class Claims:
    def __init__(self):
        self.claims = []
        self.filings = []
        self.moves = []

    def wrap(self, model, rules, store, items):
        def run(prompt):
            shown = {}
            section = None
            for line in prompt.splitlines():
                if line == '## Core rules (ids in brackets)':
                    section = 'core.md'
                elif line.startswith('### '):
                    section = line[4:]
                elif line.startswith('## '):
                    section = None
                match = re.fullmatch(r'- \[([0-9a-f]{8})\] (.*)', line)
                if match and section:
                    shown[(section, match[1])] = match[2]
            with open(PROMPT) as f:
                guide = f.read()
            # Insert before the numbered items, so the latter retain their existing format.
            heading = '\n## Items to file\n'
            before, marker, after = prompt.rpartition(heading)
            text = model(before + '\n' + guide + '\n' + marker + after if marker else prompt)
            try:
                data = lore_master.decode_reply(text)
            except lore_master.ReplyError:
                return text
            has_claims = 'duplicates' in data
            claims = data.pop('duplicates', None)
            repeated = []
            def pairs(values):
                result = {}
                for key, value in values:
                    if key in result:
                        repeated.append(key)
                    result[key] = value
                return result
            candidates = [text.strip()] + [m.group(1) for m in lore_master.FENCE_RE.finditer(text.strip())]
            t = text.strip()
            if 0 <= t.find('{') < t.rfind('}'):
                candidates.append(t[t.find('{'):t.rfind('}') + 1])
            for candidate in candidates:
                try:
                    json.loads(candidate, object_pairs_hook=pairs)
                    break
                except ValueError:
                    repeated.clear()
            if isinstance(claims, list) and not repeated:
                self.claims.append((rules, shown, claims, len(self.moves)))
            ops = data.get('ops')
            checked, errors = lore_master._run(store, ops, items, lore_master.LOREMASTER_OPS)
            if not errors:
                m = lore_master._Model(store)
                for op in ops:
                    kind = op['op']
                    old_ids = set(m.ids())
                    rel = None
                    if kind == 'supersede':
                        rel, _ = m.find(op['rule_id'], op.get('file'))
                    lore_master._step(m, kind, op, items)
                    if kind in ('add', 'supersede'):
                        rid = op['rule_id'] if kind == 'supersede' else next(iter(set(m.ids()) - old_ids))
                        rel = rel if kind == 'supersede' else op['file']
                        quote = lore_master._tidy(op['quote'])
                        matches = [rule for rule, item in zip(rules, items)
                                   if quote == lore_master._tidy(item.get('quote') or item['text'])]
                        if len(matches) == 1:
                            self.filings.append((matches[0]['id'], rel, rid, quote, len(self.moves) + len(m.moved)))
                self.moves.extend(checked.moved)
            return json.dumps(data) if has_claims else text
        return run

    def direct(self, store, rules):
        model = lore_master._Model(store)
        result = {r['id']: [] for r in rules}
        identities = {r['id']: [] for r in rules}
        filed_ids = {r['id']: set() for r in rules}
        for key, rel, rid, quote, offset in self.filings:
            filed_ids[key].add((lore_master.follow(rel, rid, self.moves[offset:]), rid))
        for key, rel, rid, quote, offset in self.filings:
            rel = lore_master.follow(rel, rid, self.moves[offset:])
            entry = model.entries(rel).get(rid) if rel in model.files else None
            if entry and lore_master.original_quote(entry) == quote:
                result[key].append((rel, entry['text']))
                if len(filed_ids[key]) == 1:
                    identity = (rel, rid, entry['text'])
                    if identity not in identities[key]:
                        identities[key].append(identity)
        return result, identities

    def resolve(self, store, rules, direct, identities):
        model = lore_master._Model(store)
        raw = {}
        for batch, shown, claims, offset in self.claims:
            for claim in claims:
                if not isinstance(claim, dict):
                    continue
                n = claim.get('input')
                if type(n) is not int or not 1 <= n <= len(batch):
                    continue
                source = batch[n - 1]
                raw.setdefault(source['id'], []).append((claim, batch, shown, n, offset))
        candidates = []
        where = {key: list(value) for key, value in direct.items()}
        by_id = {r['id']: r for r in rules}
        for key, entries in raw.items():
            if len(entries) != 1 or direct[key]:
                continue
            claim, batch, shown, n, offset = entries[0]
            target = None
            if set(claim) == {'input', 'file', 'rule_id'}:
                pair = (claim['file'], claim['rule_id'])
                if all(isinstance(x, str) for x in pair) and pair in shown:
                    rel, rid = pair
                    rel = lore_master.follow(rel, rid, self.moves[offset:])
                    entry = model.entries(rel).get(rid) if rel in model.files else None
                    if entry and lore.redact(entry.get('text', '')) == shown[pair]:
                        target = (rel, rid, entry['text'])
            elif set(claim) == {'input', 'earlier_input'}:
                earlier = claim['earlier_input']
                if type(earlier) is int and 1 <= earlier < n:
                    hits = identities[batch[earlier - 1]['id']]
                    if len(hits) == 1:
                        target = hits[0]
            if target:
                rel, rid, words = target
                where[key] = [(rel, words)]
                candidates.append({'id': key, 'original': by_id[key]['text'], 'file': rel,
                                   'rule_id': rid, 'text': words})
        return where, candidates


def render(provisional):
    out = ["## Provisional duplicate matches", "",
           "These adjusted scores assume every candidate is confirmed by the owner; direct scores above remain authoritative.",
           "For confirmed scores, use report.json: start from direct rules and pairs, substitute only owner-confirmed",
           "candidate locations, then count correct folders and pairs in one file or linked (denominators unchanged).", ""]
    for name in ("folder", "related"):
        bar = provisional["bars"][name]
        out.append(f"- {name}: {bar['n']}/{bar['d']} provisional")
    out.append("")
    for c in provisional["candidates"]:
        out.append(f"- {c['id']}: {c['original']} → {c['file']} [{c['rule_id']}]: {c['text']}")
    return out + [""]


def spot_sheet(rows, candidates):
    def cell(text):
        return " ".join(str(text).split()).replace("|", "\\|")
    out = ["# Meaning spot-check", "",
           f"{len(rows)} rules, chosen by a fixed sort (sha1 of the id). For each, does the filed wording say what "
           "the original says, no more and no less? Write yes or no in the last column. The tool judges nothing.",
           "", "| # | id | original wording | filed wording (file) | yes/no |", "|---|---|---|---|---|"]
    provisional = {c["id"] for c in candidates}
    for n, r in enumerate(rows, 1):
        filed = "<br>".join(f"{cell(x['text'])} ({x['file']})" for x in r["filed"]) or "(not filed)"
        if r["id"] in provisional:
            filed += " [provisional duplicate match]"
        out.append(f"| {n} | {r['id']} | {cell(r['original'])} | {filed} |  |")
    return "\n".join(out) + "\n"
