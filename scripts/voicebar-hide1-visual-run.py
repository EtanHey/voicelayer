#!/usr/bin/env python3
"""Compatibility entry for the committed shared native safety supervisor."""
import argparse
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location('safety', pathlib.Path(__file__).with_name('voicebar-ui-e2e-supervisor.py'))
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


def main(output):
    return safety.supervise(safety.NativeHost(output, 'hide1'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    import signal
    host = safety.NativeHost(args.output.resolve(), 'hide1')
    for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(sig, lambda number, frame: host.cancelled.append(number))
    sys.exit(safety.supervise(host))
