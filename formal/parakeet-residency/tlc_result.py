"""Validate TLC success or a counterexample on the intended property."""
import re


def valid_result(code, text, expected, config):
    invariants = re.findall(r'Invariant (\w+) is violated', text)
    actions = re.findall(r'Action property (\w+) is violated', text)
    temporal = re.findall(r'Temporal property (\w+) was violated\.', text)
    legacy_temporal = 'Temporal properties were violated.' in text
    if expected is None:
        return code == 0 and 'No error has been found.' in text
    if code == 12:
        return bool(invariants) and all(name == expected for name in invariants)
    if code == 13:
        # TLC 2.19 reports an unnamed temporal failure; nightlies name it.
        # A named failure must never be accepted through the legacy summary.
        names = actions + temporal
        return (not invariants and bool(names or legacy_temporal) and
                all(name == expected for name in names) and
                re.findall(r'^PROPERTY (\w+)$', config, re.M) == [expected])
    return False
