"""Export real Current/Fixed graph edges, including cancellation identity and native paths."""
import argparse
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from corpus_support import graphs, paths, write_corpus

parser = argparse.ArgumentParser()
parser.add_argument('--record', action='store_true')
args = parser.parse_args()
directory = Path(__file__).resolve().parent
wire, native, counts = {}, {}, {}
for policy, graph in graphs(directory).items():
    nodes = graph['nodes']
    counts[policy] = len(nodes)
    initial, = [key for key, node in nodes.items() if node['s']['event'] == 'init']
    shortest = paths(graph, initial)
    for source, target in sorted(graph['edges'], key=lambda edge: json.dumps([nodes[edge[0]], nodes[edge[1]]], sort_keys=True)):
        before, after = nodes[source]['s'], nodes[target]['s']
        event, take = after['event'], after['target']
        mic = [t for t in ['A', 'B'] if before['stage'][t] == 'recording']
        worker = [t for t in ['A', 'B'] if before['stage'][t] in ['transcribing', 'cancelling']]
        if event in ['socket', 'click', 'Escape'] and take in ['A', 'B']:
            phase = 'recording' if mic else 'transcribing' if worker else 'idle'
            row = dict(policy=policy, command='record' if event == 'socket' else 'cancel', origin=event,
                       phase=phase, before=before['stage'], target=take, requestId=after['requestId'],
                       outcome=after['reply'], token=after['cancelToken'] if event != 'socket' else 'none')
            wire[json.dumps(row, sort_keys=True)] = row
        if event == 'F5' and take == 'B' and before['stage']['A'] == 'transcribing' and before['stage']['B'] == 'fresh' and not mic:
            native[f'{policy}:F5'] = dict(policy=policy, kind='F5', command='record' if after['stage']['B'] == 'recording' else 'cancel', take='B' if after['stage']['B'] == 'recording' else 'A')
        if take == 'A' and before['stage']['A'] == 'transcribing' and before['stage']['B'] == 'fresh' and before['guard'] == 'none':
            if event in ['arm', 'click']:
                native[f'{policy}:click'] = dict(policy=policy, kind='click', command='none' if event == 'arm' else 'cancel', take='A')
            if event == 'Escape' and after['requestId'] == 'A':
                native[f'{policy}:Escape'] = dict(policy=policy, kind='Escape', command='cancel', take='A')
        timeline = (policy == 'Current' and event == 'new-recording-event' and take == 'A') or (
                    policy == 'Fixed' and event in ['socket','F5'] and take == 'B' and before['stage']['A'] == 'pasted' and before['stage']['B'] == 'fresh')
        if timeline and f'{policy}:delivery' not in native:
            trace = [{field: nodes[key]['s'][field] for field in ['event', 'target']} for key in shortest[source] + [target]]
            native[f'{policy}:delivery'] = dict(policy=policy, kind='delivery', trace=trace,
                                               delivered=[t for t in ['A','B'] if after['deliveries'][t] > 0])
assert len(native) == 8, native.keys()
assert {row['policy'] for row in wire.values()} == {'Current','Fixed'}
counts.update(wireCases=len(wire), nativeCases=len(native))
write_corpus(directory, dict(wire=[wire[key] for key in sorted(wire)], native=[native[key] for key in sorted(native)], counts=counts), args.record)
