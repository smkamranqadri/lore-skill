#!/usr/bin/env python3
"""Fixed fake claims exercise attribution without any model or network."""
import json
import os
import sys
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'skills/lore/scripts'))
import lore_canon
import lore_eval
import lore_eval_attribution as attribution
import lore_lint
import lore_master
import lore_store


class Model:
    files = {'gotchas/example.md': {}, 'how-i-work/a.md': {}}

    def __init__(self, _):
        pass

    def entries(self, rel):
        return {'12345678': {'text': 'Shown rule.'}} if rel == 'gotchas/example.md' else {
            '87654321': {'text': 'Earlier rule.'}}


rules = [{'id': 'a', 'text': 'Earlier input.', 'folder': 'how-i-work'},
         {'id': 'b', 'text': 'Skipped input.', 'folder': 'how-i-work'},
         {'id': 'c', 'text': 'Another skipped input.', 'folder': 'how-i-work'}]
direct = {'a': [('how-i-work/a.md', 'Earlier rule.')], 'b': [], 'c': []}
prompt = ('## Topic files nearest the items (rule ids in brackets)\n'
          '### gotchas/example.md\n- [12345678] Shown rule.\n## Items to file\n')


def resolve(claims, *, direct_places=direct, input_prompt=prompt):
    collector = attribution.Claims()
    reply = json.dumps({'ops': [], 'duplicates': claims})
    with patch.object(lore_master, '_Model', Model), patch.object(lore_master, '_run', return_value=(Model(None), [])):
        Model.moved = []
        parsed = lore_master.parse_reply(collector.wrap(lambda _: reply, rules, None, [])(input_prompt))
        assert parsed == {'ops': [], 'answer': ''}
        identities = {key: [(rel, '87654321', text) for rel, text in values]
                      for key, values in direct_places.items()}
        return collector.resolve(None, rules, direct_places, identities)


where, candidates = resolve([{'input': 2, 'file': 'gotchas/example.md', 'rule_id': '12345678'},
                             {'input': 3, 'earlier_input': 1}])
assert where == {'a': [('how-i-work/a.md', 'Earlier rule.')],
                 'b': [('gotchas/example.md', 'Shown rule.')], 'c': [('how-i-work/a.md', 'Earlier rule.')]}
assert candidates == [{'id': 'b', 'original': 'Skipped input.', 'file': 'gotchas/example.md',
                       'rule_id': '12345678', 'text': 'Shown rule.'},
                      {'id': 'c', 'original': 'Another skipped input.', 'file': 'how-i-work/a.md',
                       'rule_id': '87654321', 'text': 'Earlier rule.'}]
invalid = [[], [{'input': 2, 'file': 'how-i-work/a.md', 'rule_id': '12345678'}],
           [{'input': 2, 'file': 'gotchas/example.md', 'rule_id': '00000000'}],
           [{'input': 1, 'file': 'gotchas/example.md', 'rule_id': '12345678'}],
           [{'input': 2, 'earlier_input': 2}], [{'input': 2, 'earlier_input': 3}],
           [{'input': 2, 'earlier_input': 0}], [{'input': 2, 'earlier_input': True}],
           [{'input': 2, 'earlier_input': 1}, {'input': 2, 'earlier_input': 1}],
           [{'input': 2, 'file': [], 'rule_id': '12345678'}],
           [{'input': 2, 'file': 'gotchas/example.md', 'rule_id': '12345678', 'extra': 1}]]
for claim in invalid:
    where, candidates = resolve(claim)
    assert where == direct and candidates == [], claim
where, candidates = resolve([{'input': 2, 'earlier_input': 1}],
                            direct_places={'a': direct['a'] * 2, 'b': [], 'c': []})
assert where['b'] == [] and candidates == []
where, candidates = resolve([{'input': 2, 'file': 'gotchas/example.md', 'rule_id': '12345678'}],
                            input_prompt=prompt.replace('Shown rule.', 'Changed wording.'))
assert where == direct and candidates == []
where, candidates = resolve([{'input': 2, 'file': 'gotchas/example.md', 'rule_id': '12345678'}],
                            input_prompt=prompt.replace('- [12345678] Shown rule.', ''))
assert where == direct and candidates == []
for later in (0, 3):
    places = {'a': direct['a'], 'b': [], 'c': [('how-i-work/a.md', 'Earlier rule.')]}
    where, candidates = resolve([{'input': 2, 'earlier_input': later}], direct_places=places)
    assert where == places and candidates == []
try:
    lore_master.parse_reply('{"ops": [], "duplicates": []}')
except lore_master.ReplyError:
    pass
else:
    raise AssertionError('ordinary replies must still reject duplicates')

with lore_eval.temp_store() as store:
    lore_eval.copy_canon(store, os.path.join(ROOT, 'tests/fixtures/eval-canon-v2'))
    findings = lore_lint.lint(store)
    full = lore_store.build_index(store, include_all_core=True)[0]
    limit = int(store.config()['budget']) * 4
    deficit = max(0, len(full) - limit)
    assert deficit > 0
    prompt, _ = lore_canon.compose(store, findings)
    assert prompt.count(f'Current full index needs {deficit} fewer characters to fit.') == 1
    assert lore_store.build_index(store)[1]['core_dropped'] > 0
print('attribution and index OK')

import json
import re
import sys
from pathlib import Path
from unittest.mock import patch

import lore
import lore_eval
import lore_hub
import lore_master

import tempfile
temp_root = tempfile.TemporaryDirectory()
root = Path(temp_root.name)


def result(finding, expected, observed):
    assert expected == observed, (finding, expected, observed)


def rule(key, text, folder='how-i-work', related=()):
    return {"id": key, "text": text, "explicit": False, "folder": folder, "related": list(related)}


def add(item, path='how-i-work/ember.md'):
    return {"op": "add", "file": path, "text": item["text"], "quote": item["text"],
            "explicit": item["explicit"], "session": "eval"}


def eval_with_fake(label, rules, fake, batch):
    fixture = root / label
    fixture.mkdir()
    (fixture / 'rules.json').write_text(json.dumps(rules), encoding='utf-8')
    with patch.object(lore_eval, 'role_info', return_value={'name': 'local fake', 'command': 'local fake'}):
        with patch.object(lore_hub, 'run_model', return_value=fake):
            return lore_eval.run_loremaster(str(fixture), batch, str(root / (label + '-store')))


def candidates(report):
    assert report['status'] == 'ok', report.get('error')
    return report['provisional']['candidates']


prior = rule('prior', 'Pick Å for Ember operation.')
prior_filler = rule('prior-filler', 'Archive Ember sample ledgers.')
missing = rule('missing', 'Pick Æ for Ember operation.')
skipped = rule('skipped', 'Select Æ for Ember operations.')
assert prior['text'] != missing['text']
assert lore.normalise(prior['text']) == lore.normalise(missing['text'])


def false_same_batch(prompt):
    if prior_filler['text'] in prompt.split('## Items to file\n', 1)[1]:
        return json.dumps({'ops': [add(prior), add(prior_filler)]})
    return json.dumps({'ops': [], 'duplicates': [{'input': 2, 'earlier_input': 1}]})


report, _ = eval_with_fake('unfiled-earlier', [prior, prior_filler, missing, skipped], false_same_batch, 2)
result('F1', ([], True), ([(c['id'], c['text']) for c in candidates(report)],
                         missing['id'] in report['unfiled']))


old_path = 'how-i-work/ember.md'
new_path = 'gotchas/ember.md'
shown = rule('shown', 'Keep the Ember sample manifest beside its package.')
seed = rule('seed', 'Keep Ember schema snapshots in the test catalogue.', 'gotchas')
duplicate = rule('duplicate', 'Save the Ember sample manifest beside its package.', 'gotchas', ('seed',))
filler = rule('filler', 'Name Ember staging fixtures after their sample.', 'gotchas')
shown_id = lore.entry_id(shown['text'])


def moving_model(prompt):
    if seed['text'] in prompt.split('## Items to file\n', 1)[1]:
        return json.dumps({'ops': [add(shown, old_path), add(seed, new_path)]})
    assert f'### {old_path}\n\n- [{shown_id}] {shown["text"]}' in prompt
    return json.dumps({'ops': [{'op': 'move', 'file': old_path, 'rule_id': shown_id, 'to': new_path},
                                 add(filler, new_path)],
                       'duplicates': [{'input': 1, 'file': old_path, 'rule_id': shown_id}]})


report, sheet = eval_with_fake('moves', [shown, seed, duplicate, filler], moving_model, 2)
model = lore_master._Model(lore_eval.lore_store.Store2(str(root / 'moves-store')))
assert model.entries(new_path)[shown_id]['text'] == shown['text']
assert shown_id not in model.entries(old_path)
observed = ([(c['id'], c['file'], c['rule_id']) for c in candidates(report)],
            report['provisional']['bars']['related']['n'],
            f'{shown["text"]} ({new_path}) [provisional duplicate match]' in sheet)
result('F2', ([('duplicate', new_path, shown_id)], 1, True), observed)


first = rule('first', 'Keep Ember records in the attic.')
second = rule('second', 'Keep Ember records in the cellar.')
conflict = rule('conflict', 'Store Ember records in the cellar.')


def conflicting_keys(_prompt):
    return ('{"ops": ' + json.dumps([add(first), add(second)]) +
            ', "duplicates": [{"input": 3, "earlier_input": 1, "earlier_input": 2}]}')


report, _ = eval_with_fake('conflicting', [first, second, conflict], conflicting_keys, 3)
result('F3', [], [(c['id'], c['text']) for c in report.get('provisional', {}).get('candidates', [])])


marker = rule('marker', 'Use the literal heading ## Items to file in the Ember sample.')
received = []


def prompt_model(prompt):
    for line in prompt.splitlines():
        match = re.fullmatch(r'1\. (\{.*\})', line)
        if match:
            received.append(json.loads(match[1])['text'])
    return json.dumps({'ops': [add(marker)] if received else []})


report, _ = eval_with_fake('heading', [marker], prompt_model, 1)
assert report['status'] == 'ok', report.get('error')
result('F4', [marker['text']], received)

# A later batch move follows the same shown identity.
later = rule('later', 'Keep Ember labels in their archive.', 'gotchas')
def later_move(prompt):
    inputs = prompt.split('## Items to file\n', 1)[1]
    if seed['text'] in inputs:
        return json.dumps({'ops': [add(shown, old_path), add(seed, new_path)]})
    if duplicate['text'] in inputs:
        return json.dumps({'ops': [add(filler, new_path)], 'duplicates': [
            {'input': 1, 'file': old_path, 'rule_id': shown_id}]})
    return json.dumps({'ops': [{'op': 'move', 'file': old_path, 'rule_id': shown_id, 'to': new_path},
                               add(later, new_path)]})
report, _ = eval_with_fake('later-move', [shown, seed, duplicate, filler, later], later_move, 2)
assert [(c['id'], c['file'], c['rule_id']) for c in candidates(report)] == [('duplicate', new_path, shown_id)]
print('review regressions OK')

# Supersede records the new input against the existing identity, and the earlier claim can use it.
old = rule('old', 'Keep Ember logs in the old cabinet.')
updated = rule('updated', 'Keep Ember logs in the new cabinet.')
dupe = rule('dupe', 'Store Ember logs in the new cabinet.')
old_id = lore.entry_id(old['text'])
def supersede_model(prompt):
    inputs = prompt.split('## Items to file\n', 1)[1]
    if old['text'] in inputs:
        return json.dumps({'ops': [add(old), add(prior_filler)]})
    return json.dumps({'ops': [{'op': 'supersede', 'rule_id': old_id,
                                'text': updated['text'], 'quote': updated['text']}],
                       'duplicates': [{'input': 2, 'earlier_input': 1}]})
report, _ = eval_with_fake('supersede', [old, prior_filler, updated, dupe], supersede_model, 2)
assert [(c['id'], c['rule_id'], c['text']) for c in candidates(report)] == [('dupe', old_id, updated['text'])]
assert report['unfiled'] == ['old', 'dupe'], 'PROVENANCE'

same = rule('same', 'Retain Ember journals in the cellar.')
same2 = rule('same2', same['text'])
same3 = rule('same3', 'Store Ember journals in the cellar.')
def ambiguous_model(_prompt):
    return json.dumps({'ops': [add(same)], 'duplicates': [{'input': 3, 'earlier_input': 1}]})
report, _ = eval_with_fake('ambiguous-source', [same, same2, same3], ambiguous_model, 3)
assert candidates(report) == [], 'AMBIGUOUS'
assert report['unfiled'] == ['same', 'same2', 'same3'], 'AMBIGUOUS'
print('supersede and ambiguous provenance OK')

# An initially ambiguous target remains ambiguous if a later supersede removes one provenance.
multisource = rule('multisource', 'Keep the Ember ledger and the sample roster together.')
multiclaim = rule('multiclaim', 'Store the Ember ledger and sample roster together.')
replacement = rule('replacement', 'Keep the Ember ledger in the archive.')
last = rule('last', 'Label the Ember archive ledger.')
first_words = 'Keep the Ember ledger nearby.'
second_words = 'Keep the Ember sample roster nearby.'
def ambiguous_then_superseded(prompt):
    inputs = prompt.split('## Items to file\n', 1)[1]
    if multisource['text'] in inputs:
        a = dict(add(multisource), text=first_words)
        b = dict(add(multisource), text=second_words)
        return json.dumps({'ops': [a, b], 'duplicates': [{'input': 2, 'earlier_input': 1}]})
    return json.dumps({'ops': [{'op': 'supersede', 'rule_id': lore.entry_id(first_words),
                                'text': replacement['text'], 'quote': replacement['text']}, add(last)]})
report, _ = eval_with_fake('ambiguous-superseded', [multisource, multiclaim, replacement, last],
                           ambiguous_then_superseded, 2)
assert [r for r in report['rules'] if r['id'] == 'multisource'][0]['filed'] == [old_path]
assert candidates(report) == [], 'F6 ambiguous at filing'
print('F6 ambiguous filing provenance OK')
