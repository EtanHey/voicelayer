#!/usr/bin/env python3
"""Own the native gate lifecycle: read-only preflight, own-UI Hide/Show, mute guard, restore."""
import argparse
import datetime
import importlib.util
import json
import os
import pathlib
import secrets
import signal
import subprocess
import sys
import time


def safe_to_hide(capture_children, fresh_locks, ax_labels):
    blocked = ['Recording', 'Starting microphone', 'Stop recording', 'Cancel recording']
    if capture_children or fresh_locks or any(x.startswith(tuple(blocked)) for x in ax_labels):
        return False
    # Require positive AX evidence. A collapsed/empty tree is UNKNOWN, never idle.
    return any(x == 'Start voice recording' or x.startswith(('Ready.', 'Hidden until ', 'Hidden for '))
               or x in ['Ready', 'Transcribing', 'Agent speaking'] for x in ax_labels)


def wait_until_safe(host):
    for attempt in range(3):
        if host.preconditions():
            return
        if attempt < 2:
            host.wait(120)
    raise RuntimeError('Resident preconditions unknown/unsafe after bounded wait/recheck; no capture interrupted')


def require_supervisor(output, environment):
    proof = json.loads((output / 'supervisor-authority.json').read_text())
    if (proof.get('pid') != os.getppid() or not proof.get('token')
            or proof['token'] != environment.get('VOICEBAR_UIE2E_SUPERVISOR_TOKEN')):
        raise ValueError('Native launch requires its live parent safety supervisor')


def supervise(host):
    receipt = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'suiteExit': None,
               'exportExit': None, 'cleanupErrors': []}
    initial = None
    try:
        initial = host.muted()
        receipt['initialMuted'] = initial
        host.set_mute(True)
        host.prepare_resident()
        host.start()
        while host.poll() is None:
            host.check()  # Continuous mute, disk, permission and tripwire checks.
            host.wait(1)
        host.check()
        receipt['suiteExit'] = host.poll()
    except BaseException as error:
        receipt['error'] = repr(error)
    finally:
        # Independent cleanup legs: child cleanup/Show failure must never skip mute restore.
        for name in ['stop', 'restore_resident']:
            try:
                getattr(host, name)()
            except BaseException as error:
                receipt['cleanupErrors'].append(name + ': ' + repr(error))
        if initial is not None:
            try:
                host.set_mute(initial)
                receipt['muteRestored'] = host.muted() == initial
            except BaseException as error:
                receipt['cleanupErrors'].append('mute: ' + repr(error))
        receipt['finished'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        host.save(receipt)
    if receipt['suiteExit'] is not None:
        try:
            receipt['exportExit'] = host.export()
        except BaseException as error:
            receipt['error'] = repr(error)
        host.save(receipt)
    return int(bool(receipt.get('error') or receipt['cleanupErrors'] or
                    receipt['suiteExit'] != 0 or receipt['exportExit'] != 0))


class NativeHost:
    def __init__(self, output, scenario):
        self.output, self.scenario = output, scenario
        self.repo = pathlib.Path(__file__).resolve().parent.parent
        self.sandbox = pathlib.Path((output / 'sandbox-path.txt').read_text().strip())
        self.child = None
        self.resident = {}
        self.checks = []
        self.cancelled = []
        self.deadline = None
        self.log = None

    def run(self, args):
        return subprocess.check_output(args, text=True, timeout=15).strip()

    def muted(self):
        value = self.run(['osascript', '-e', 'output muted of (get volume settings)'])
        if value not in ['true', 'false']:
            raise RuntimeError('Unknown output-mute state')
        return value == 'true'

    def set_mute(self, value):
        subprocess.run(['osascript', '-e', 'set volume output muted ' + str(value).lower()], check=True, timeout=15)
        if self.muted() != value:
            raise RuntimeError('Mute change unconfirmed')

    def ax(self, mode):
        result = json.loads(self.run([str(self.output / 'voicebar-ui-e2e-resident'), str(self.resident['pid']), mode]))
        if mode != 'read':
            self.resident.setdefault('actions', []).append(mode)
            self.save_resident()
        return result

    def save_resident(self):
        (self.output / 'resident-visibility.json').write_text(json.dumps(self.resident, indent=2) + '\n')

    def process_rows(self):
        rows = {}
        for line in self.run(['ps', '-axo', 'pid=,ppid=,comm=']).splitlines():
            pid, parent, cmd = line.strip().split(None, 2)
            rows[int(pid)] = (int(parent), cmd)
        return rows

    def identity(self, pid):
        return self.run(['ps', '-p', str(pid), '-o', 'lstart='])

    def preconditions(self):
        rows = self.process_rows()
        pid = self.resident['pid']
        if rows.get(pid, (None, None))[1] != '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar' or self.identity(pid) != self.resident['started']:
            raise RuntimeError('Resident identity changed; no action permitted')
        daemons = [p for p, (parent, _) in rows.items() if parent == pid and
                   'mcp-server-daemon.ts' in self.run(['ps', '-p', str(p), '-o', 'args='])]
        if len(daemons) != 1:
            return False
        daemon = daemons[0]
        identity = self.identity(daemon)
        if 'daemonPid' in self.resident and (daemon != self.resident['daemonPid'] or identity != self.resident['daemonStarted']):
            raise RuntimeError('Resident daemon identity changed; no action permitted')
        self.resident.update(daemonPid=daemon, daemonStarted=identity)
        descendants = {daemon}
        while True:
            extended = descendants | {p for p, (parent, _) in rows.items() if parent in descendants}
            if extended == descendants:
                break
            descendants = extended
        capture = [p for p in descendants if pathlib.Path(rows[p][1]).name in ['rec', 'sox']]
        locks = []
        for path in pathlib.Path('/tmp').glob('voicelayer-session-*.lock'):
            try:
                if time.time() - path.stat().st_mtime < 300:
                    locks.append(path.name)
            except FileNotFoundError:
                pass
        nodes = self.ax('read')['nodes']
        labels = [x for node in nodes for key in ['title', 'description', 'value'] if (x := node.get(key))]
        safe = safe_to_hide(capture, locks, labels)
        self.resident.setdefault('preconditions', []).append(dict(capturePids=capture, freshLocks=locks,
                                                               axLabels=labels, safe=safe))
        self.save_resident()
        return safe

    def prepare_resident(self):
        permission = json.loads(self.run([str(self.output / 'voicebar-ui-e2e-permissions')]))
        if permission.get('axTrusted') is not True or permission.get('prompts') != []:
            raise RuntimeError('STOP: permission preflight; never dismiss/grant')
        residents = [p for p, (_, cmd) in self.process_rows().items()
                     if cmd == '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar']
        if len(residents) != 1:
            raise RuntimeError('Exactly one installed resident required; never launch/replace one')
        self.resident = dict(pid=residents[0], started=self.identity(residents[0]), restoreRequired=False,
                             settingsOpened=False)
        self.save_resident()
        nodes = self.ax('read')['nodes']
        if any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings' for n in nodes):
            raise RuntimeError('Resident Settings already open; cannot close a user-owned window')
        # Own Settings exposes a positive recording-state footer even with a collapsed pill.
        self.resident['settingsOpened'] = True
        self.save_resident()
        self.ax('open')
        wait_until_safe(self)
        nodes = self.ax('read')['nodes']
        self.resident['initialHidden'] = any('Show VoiceBar' in [n.get('title'), n.get('description')] for n in nodes)
        if not self.resident['initialHidden']:
            self.resident['restoreRequired'] = True  # Write BEFORE a possibly applied AX press.
            self.save_resident()
            result = self.ax('hide')
            if not any('Show VoiceBar' in [n.get('title'), n.get('description')] for n in result['nodes']):
                raise RuntimeError('Own Hide unconfirmed; no workaround')
        self.save_resident()

    def start(self):
        wait_until_safe(self)  # Recheck before launch, with hidden-state AX footer readable.
        self.ax('close')
        self.resident['settingsOpened'] = False
        self.save_resident()
        if self.ax('read')['screenWindows']:
            raise RuntimeError('Resident window remains on screen after own Hide')
        self.check()
        subprocess.run([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-results.py'), 'configure',
                        str(self.output), str(self.sandbox / 'VoiceBarQA.app'), str(self.sandbox),
                        '--scenario', self.scenario], check=True)
        token = secrets.token_hex(24)
        with (self.output / 'supervisor-authority.json').open('x') as file:
            json.dump(dict(pid=os.getpid(), token=token), file)
        env = dict(os.environ, VOICEBAR_UIE2E_SUPERVISOR_TOKEN=token,
                   VOICEBAR_UIE2E_RESIDENT_SNAPSHOT=str(self.output / 'resident-visibility.json'))
        self.log = (self.output / 'supervisor.log').open('w')
        self.deadline = time.monotonic() + 300
        self.child = subprocess.Popen([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-run.py'),
                                      str(self.output), '--scenario', self.scenario], env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT)

    def poll(self):
        return self.child.poll() if self.child is not None else None

    def check(self):
        import shutil
        permissions = json.loads(self.run([str(self.output / 'voicebar-ui-e2e-permissions')]))
        free = shutil.disk_usage('/System/Volumes/Data').free
        muted = self.muted()
        self.checks.append(dict(muted=muted, freeBytes=free, permissions=permissions))
        if not muted or free < (10 if self.child else 15) * 1024**3:
            raise RuntimeError('Mute lost or disk threshold crossed')
        if permissions.get('axTrusted') is not True or permissions.get('prompts') != []:
            raise RuntimeError('STOP: permission prompt or unreadable AX; never dismiss/grant')
        guard = self.sandbox / 'no-device-guard.log'
        if guard.exists() and guard.read_text() != 'voicebar-no-device-guard-v1:installed\n':
            raise RuntimeError('Device tripwire invoked')
        if self.cancelled or (self.deadline and time.monotonic() > self.deadline):
            raise InterruptedError('Native gate cancelled/deadline reached')

    def wait(self, seconds):
        end = time.monotonic() + seconds
        next_check = time.monotonic()
        while time.monotonic() < end:
            if self.cancelled:
                raise InterruptedError('Supervisor interrupted')
            if time.monotonic() >= next_check:
                self.check()
                next_check = time.monotonic() + 1
            time.sleep(min(.2, max(0, end - time.monotonic())))

    def stop(self):
        if self.child is not None and self.child.poll() is None:
            self.child.send_signal(signal.SIGINT)  # Only owned supervisor child; it flushes media/restores apps.
            self.child.wait(timeout=45)
        if self.log:
            self.log.close()
        # An interrupted XCTest can leave QA alive. Never match by name or resident PID.
        expected = str((self.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
        for pid, (_, cmd) in self.process_rows().items():
            if cmd == expected:
                os.kill(pid, signal.SIGTERM)

    def restore_resident(self):
        if not self.resident:
            return
        if self.identity(self.resident['pid']) != self.resident['started']:
            raise RuntimeError('Cannot restore changed resident identity')
        if self.resident.get('restoreRequired'):
            if not self.resident.get('settingsOpened'):
                self.ax('open'); self.resident['settingsOpened'] = True
            result = self.ax('show')
            if not any('Hide VoiceBar for 1 hour' in [n.get('title'), n.get('description')] for n in result['nodes']):
                raise RuntimeError('Own Show unconfirmed')
            self.resident['restoreRequired'] = False
            self.resident['restored'] = True
        if self.resident.get('settingsOpened'):
            self.ax('close'); self.resident['settingsOpened'] = False
        self.resident['identitiesUnchanged'] = self.identity(self.resident['daemonPid']) == self.resident['daemonStarted'] if 'daemonPid' in self.resident else True
        self.save_resident()
        if not self.resident['identitiesUnchanged']:
            raise RuntimeError('Resident daemon identity changed during gate')

    def export(self):
        return subprocess.call([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-results.py'),
                                'export', str(self.output), str(self.sandbox), '--scenario', self.scenario])

    def save(self, receipt):
        receipt['checks'] = self.checks
        (self.output / 'operator-state.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--scenario', default='full', choices=['full', 'hide1', 'gate2246', 'focused-338'])
    args = parser.parse_args()
    host = NativeHost(args.output.resolve(), args.scenario)
    # Latch signals through cleanup; restoration cannot be interrupted by a second signal.
    for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(sig, lambda number, frame: host.cancelled.append(number))
    sys.exit(supervise(host))
