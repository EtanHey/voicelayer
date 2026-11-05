#!/usr/bin/env python3
"""Run the existing recorded UI harness only inside a Virtualization.framework guest."""
import argparse
import importlib.util
import json
import os
import pathlib
import secrets
import signal
import subprocess
import sys

spec = importlib.util.spec_from_file_location('ui_safety', pathlib.Path(__file__).with_name('voicebar-ui-e2e-supervisor.py'))
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


def require_guest():
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True, timeout=10).strip()
    if not model.startswith('VirtualMac'):
        raise RuntimeError('Guest UI execution refused on physical host: ' + model)
    return model


class GuestHost(safety.NativeHost):
    """A fresh guest legitimately has no installed resident; retain all other safety checks."""
    def prepare_resident(self):
        self.preflight['guestModel'] = require_guest()
        # Never adopt a guest resident either: this is a QA-only environment.
        rows = subprocess.run(['pgrep', '-x', 'VoiceBar'], capture_output=True, text=True, timeout=10)
        if rows.returncode != 1:
            raise RuntimeError('Guest must have no pre-existing VoiceBar process')
        self.check()
        self.preflight['residentPolicy'] = 'absent-in-isolated-guest'

    def start(self):
        require_guest()
        self.check()
        subprocess.run([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-results.py'), 'configure',
                        str(self.output), str(self.sandbox / 'VoiceBarQA.app'), str(self.sandbox),
                        '--scenario', self.scenario], check=True, timeout=120)
        token = self.token = secrets.token_hex(24)
        with (self.output / 'supervisor-authority.json').open('x') as file:
            json.dump(dict(pid=os.getpid(), birth=list(safety.kernel_birth(os.getpid())), token=token), file)
        env = dict(os.environ, VOICEBAR_UIE2E_SUPERVISOR_TOKEN=token)
        self.log = (self.output / 'supervisor.log').open('w')
        self.deadline = safety.time.monotonic() + safety.SCENARIO_BUDGET_SECONDS[self.scenario]
        self.runner_launch_attempted = True
        self.child = subprocess.Popen([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-run.py'),
                                      str(self.output), '--scenario', self.scenario], env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        self.remember(self.child.pid, 'runner')

    def restore_resident(self):
        if self.resident:
            raise RuntimeError('Unexpected resident adoption inside guest')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--scenario', choices=['full', 'focused-338', 'hide1', 'gate2246'], default='full')
    args = parser.parse_args()
    require_guest()  # Before constructing a host, changing mute, requesting permissions or launching UI.
    with safety.supervisor_lock():
        host = GuestHost(args.output.resolve(), args.scenario)
        for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
            signal.signal(sig, lambda number, frame: host.cancelled.append(number))
        return safety.supervise(host)


if __name__ == '__main__':
    sys.exit(main())
