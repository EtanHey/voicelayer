#!/usr/bin/env python3
"""Run an already-built HIDE1 QA candidate with a monitored mute guard and restoration."""
import argparse
import json
import pathlib
import signal
import subprocess
import sys
import time


def muted():
    value = subprocess.check_output(['osascript', '-e', 'output muted of (get volume settings)'], text=True).strip()
    if value not in {'true', 'false'}:
        raise RuntimeError('Unknown output mute state: ' + value)
    return value == 'true'


def set_mute(value):
    subprocess.run(['osascript', '-e', 'set volume output muted ' + str(value).lower()], check=True)
    if muted() != value:
        raise RuntimeError('Output mute change unconfirmed')


def main(output):
    repo = pathlib.Path(__file__).resolve().parent.parent
    sandbox = pathlib.Path((output / 'sandbox-path.txt').read_text().strip())
    initial = muted()
    receipt = {'initialMuted': initial, 'muteChecks': 0, 'suiteExit': None, 'exportExit': None}
    process = None
    try:
        set_mute(True)
        subprocess.run([sys.executable, str(repo / 'scripts/voicebar-ui-e2e-results.py'), 'configure',
                        str(output), str(sandbox / 'VoiceBarQA.app'), str(sandbox), '--scenario', 'hide1'], check=True)
        process = subprocess.Popen([sys.executable, str(repo / 'scripts/voicebar-ui-e2e-run.py'),
                                    str(output), '--scenario', 'hide1'])
        while process.poll() is None:
            if not muted():
                process.terminate()
                raise RuntimeError('Mute guard changed during native run')
            receipt['muteChecks'] += 1
            time.sleep(1)
        receipt['suiteExit'] = process.returncode
        receipt['exportExit'] = subprocess.call([sys.executable, str(repo / 'scripts/voicebar-ui-e2e-results.py'),
            'export', str(output), str(sandbox), '--scenario', 'hide1'])
        return int(receipt['suiteExit'] != 0 or receipt['exportExit'] != 0)
    except BaseException as error:
        receipt['error'] = str(error)
        raise
    finally:
        try:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=40)  # supervisor restores visibility and flushes the movie
        finally:
            set_mute(initial)
            receipt['finalMuted'] = muted()
            receipt['muteRestored'] = receipt['finalMuted'] == initial
            (output / 'operator-state.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise InterruptedError('Operator interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    sys.exit(main(parser.parse_args().output.resolve()))
