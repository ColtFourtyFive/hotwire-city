#!/usr/bin/env python3
"""Rebuild confirmed findings (finding + skeptic verdict real=true) from a workflow journal."""
import json, sys
from collections import Counter
journal, out = sys.argv[1], sys.argv[2]
fs, vs, order = {}, {}, []
for line in open(journal):
    j = json.loads(line)
    if j.get('type') != 'result':
        continue
    r = j['result']
    if isinstance(r, dict) and 'findings' in r:
        for f in r['findings']:
            key = f['id']
            while key in fs:
                key += "'"
            f['id'] = key
            fs[key] = f
            order.append(key)
    if isinstance(r, dict) and 'verdicts' in r:
        for v in r['verdicts']:
            vs[v['id']] = v
conf = []
for k in order:
    f, v = fs[k], vs.get(k)
    if v and v['real']:
        conf.append({**f, 'severity': v['severity'], 'verifyReason': v['reason'], 'fix': v.get('refinedFix') or f['suggestedFix']})
json.dump(conf, open(out, 'w'), indent=1)
print(len(fs), 'found', len(conf), 'confirmed', dict(Counter(f['severity'] for f in conf)))
for f in conf:
    print(f"[{f['severity']}] {f['id']}: {f['summary'][:130]}")
