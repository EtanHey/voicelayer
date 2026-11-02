"""Generate BOTH policy corpora from actual TLC states and cause-ending edges."""
import argparse
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from corpus_support import graphs, write_corpus

parser = argparse.ArgumentParser()
parser.add_argument('--record', action='store_true')
args = parser.parse_args()
directory = Path(__file__).resolve().parent
all_graphs = graphs(directory)
rows, lifecycle, counts = {}, {}, {}
for policy, graph in all_graphs.items():
    counts[policy] = len(graph['nodes'])
    for node in graph['nodes'].values():
        inputs = {key: value for key, value in node['s'].items() if key not in {'raised', 'timer'}}
        inputs['transientNoteOffersHistory'] = inputs['note'] == 'busy'
        row = dict(policy=policy, input=inputs, expected={key: node['shown'][key] for key in ['shell','text','wingText','band','visible','transient','historyInline']})
        rows[json.dumps(row, sort_keys=True)] = row
    for source, target in graph['edges']:
        before, after = graph['nodes'][source]['s'], graph['nodes'][target]['s']
        if before['mode'] == 'recording' and after['mode'] == 'idle' and before['note'] == 'quit' and not before['preview'] and not before['updateBusy']:
            lifecycle[policy] = dict(policy=policy, events=['recording', 'quit-refusal', 'idle'], noteVisible=after['note'] == 'quit')
assert set(lifecycle) == {'Current', 'Fixed'}
counts['projections'] = len(rows)
write_corpus(directory, dict(rows=[rows[key] for key in sorted(rows)], lifecycle=list(lifecycle.values()), counts=counts), args.record)
