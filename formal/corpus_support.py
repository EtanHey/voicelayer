"""Parse TLC values and paths without replacing model outcomes with harness rules."""
import hashlib
import json
from pathlib import Path
import re
from collections import deque

TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|\|->|<<|>>|/\\|[\[\]{}=,]|-?\d+|[A-Za-z_]\w*')

def state(label):
    tokens = TOKEN.findall(label)
    index = 0
    def take(expected=None):
        nonlocal index
        value = tokens[index]
        index += 1
        assert expected is None or value == expected, (expected, value)
        return value
    def value():
        token = take()
        if token == '[':
            result = {}
            while tokens[index] != ']':
                key = take(); take('|->'); result[key] = value()
                if tokens[index] == ',': take(',')
            take(']'); return result
        if token in {'{', '<<'}:
            result, end = [], '}' if token == '{' else '>>'
            while tokens[index] != end:
                result.append(value())
                if tokens[index] == ',': take(',')
            take(end); return sorted(result) if token == '{' else result
        if token in {'TRUE', 'FALSE'}: return token == 'TRUE'
        if token.startswith('"'): return json.loads(token)
        return int(token) if re.fullmatch(r'-?\d+', token) else token
    result = {}
    while index < len(tokens):
        if tokens[index] == '/\\': take()
        key = take(); take('='); result[key] = value()
    return result

def graphs(directory):
    root = directory.parents[1]
    cache = root / '.build.noindex' / directory.name
    receipt = json.loads((cache / 'run.json').read_text())
    assert receipt['complete'], 'A partial/debug TLC run cannot supply a corpus'
    manifest = json.loads((directory / 'checks.json').read_text())
    spec = directory / (manifest['module'] + '.tla')
    assert receipt['hashes'][str(spec.relative_to(root))] == hashlib.sha256(spec.read_bytes()).hexdigest(), 'Spec/corpus drift'
    output = {}
    for policy in ['Current', 'Fixed']:
        graph_file = cache / f'{policy.lower()}-graph.json'
        assert hashlib.sha256(graph_file.read_bytes()).hexdigest() == receipt['graphHashes'][policy], 'TLC graph checksum mismatch'
        graph = json.loads(graph_file.read_text())
        nodes = {key: state(label) for key, label in graph['nodes'].items()}
        output[policy] = dict(nodes=nodes, edges=graph['edges'])
    return output

def paths(graph, initial):
    adjacent = {}
    for source, target in graph['edges']: adjacent.setdefault(source, []).append(target)
    todo, found = deque([initial]), {initial: []}
    while todo:
        source = todo.popleft()
        for target in sorted(adjacent.get(source, []), key=lambda key: json.dumps(graph['nodes'][key], sort_keys=True)):
            if target not in found:
                found[target] = found[source] + [target]
                todo.append(target)
    assert len(found) == len(graph['nodes'])
    return found

def write_corpus(directory, corpus, record=False):
    root = directory.parents[1]
    corpus['modelSHA256'] = hashlib.sha256((directory / (json.loads((directory/'checks.json').read_text())['module'] + '.tla')).read_bytes()).hexdigest()
    encoded = json.dumps(corpus, sort_keys=True, separators=(',', ':')) + '\n'
    cache = root / '.build.noindex' / directory.name
    (cache / 'corpus.json').write_text(encoded)
    if record:
        (directory / 'corpus.json').write_text(encoded)
        (directory / 'results/corpus.json').write_text(json.dumps(dict(sha256=hashlib.sha256(encoded.encode()).hexdigest(), modelSHA256=corpus['modelSHA256']), indent=2) + '\n')
    print(f'{directory.name}: corpus {len(encoded)} bytes; {corpus["counts"]}', flush=True)
