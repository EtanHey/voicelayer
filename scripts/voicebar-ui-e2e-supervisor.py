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
        # Unmute only after positive owned-process termination proof, including on abort.
        terminated = False
        for name in ['stop', 'restore_resident']:
            try:
                host.guard_mute()
            except BaseException as error:
                receipt['cleanupErrors'].append('mute guard: ' + repr(error))
            try:
                result = getattr(host, name)()
                if name == 'stop':
                    terminated = result is True
            except BaseException as error:
                receipt['cleanupErrors'].append(name + ': ' + repr(error))
        receipt['ownedTerminationProven'] = terminated
        if not terminated:
            receipt['cleanupErrors'].append('Owned termination NOT_PROVEN; output mute retained')
        if initial is not None:
            try:
                host.set_mute(initial if terminated else True)
                receipt['muteRestored'] = terminated and host.muted() == initial
                receipt['muteRetained'] = not terminated and host.muted()
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
        self.owned = {}
        self.shutdown = []

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
        self.guard_mute()
        if self.identity(self.resident['pid']) != self.resident['started']:
            raise RuntimeError('Resident identity changed; no AX action permitted')
        args = [str(self.output / 'voicebar-ui-e2e-resident'), str(self.resident['pid']), mode]
        if mode in ['close', 'hide', 'show']:
            args.append(str(self.resident['settingsWindowId']))
        result = json.loads(self.run(args))
        if mode != 'read':
            self.resident.setdefault('actions', []).append(mode)
            self.save_resident()
        return result

    def guard_mute(self):
        if not self.muted():
            self.set_mute(True)
        if not self.muted():
            raise RuntimeError('Shutdown mute guard unconfirmed')

    def settings_state(self):
        result = self.ax('read')
        opened = any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings'
                     for n in result['nodes'])
        if opened:
            window_id = result.get('settingsWindowId')
            if not isinstance(window_id, int) or window_id <= 0:
                raise RuntimeError('Settings identity unreadable; no close permitted')
            if (not self.resident.get('settingsOpened') or
                    self.resident.get('settingsWindowId', window_id) != window_id):
                raise RuntimeError('Settings is user-owned or replaced; no action permitted')
            self.resident['settingsWindowId'] = window_id
        self.resident['settingsOpened'] = opened
        self.save_resident()
        return opened

    def settings(self, opened):
        if self.settings_state() == opened:
            return
        # Set intent before possibly-applied open. Reconcile via a fresh read even on timeout.
        if opened:
            self.resident['settingsOpened'] = True
            self.resident.pop('settingsWindowId', None)
            self.save_resident()
        try:
            self.ax('open' if opened else 'close')
        except Exception as error:
            self.resident.setdefault('reconciledActionErrors', []).append(repr(error))
            if self.settings_state() != opened:
                raise
        if self.settings_state() != opened:
            raise RuntimeError('Settings transition unconfirmed; action not retried')

    def surface(self, snapshot):
        windows = snapshot.get('screenWindows')
        if not isinstance(windows, list):
            raise RuntimeError('Resident surface evidence unreadable')
        for window in windows:
            bounds = window.get('bounds', {})
            if (not isinstance(window.get('layer'), int) or
                    not all(isinstance(bounds.get(k), (int, float)) for k in ['X', 'Y', 'Width', 'Height']) or
                    bounds['Width'] <= 0 or bounds['Height'] <= 0):
                raise RuntimeError('Resident surface geometry unreadable')
        return [dict(bounds=w['bounds'], layer=w['layer']) for w in windows]

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
        snapshot = self.ax('read')
        nodes = snapshot['nodes']
        if any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings' for n in nodes):
            raise RuntimeError('Resident Settings already open; cannot close a user-owned window')
        self.resident['initialSurface'] = self.surface(snapshot)
        # Own Settings exposes a positive recording-state footer even with a collapsed pill.
        self.settings(True)
        wait_until_safe(self)
        nodes = self.ax('read')['nodes']
        self.resident['initialHidden'] = any('Show VoiceBar' in [n.get('title'), n.get('description')] for n in nodes)
        if bool(self.resident['initialSurface']) == self.resident['initialHidden']:
            raise RuntimeError('Initial visibility and surface evidence disagree; no Hide permitted')
        if not self.resident['initialHidden']:
            self.resident['restoreRequired'] = True  # Write BEFORE a possibly applied AX press.
            self.save_resident()
            result = self.ax('hide')
            if not any('Show VoiceBar' in [n.get('title'), n.get('description')] for n in result['nodes']):
                raise RuntimeError('Own Hide unconfirmed; no workaround')
        self.save_resident()

    def start(self):
        wait_until_safe(self)  # Recheck before launch, with hidden-state AX footer readable.
        self.settings(False)
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
        self.remember(self.child.pid, 'runner')

    def poll(self):
        return self.child.poll() if self.child is not None else None

    def check(self):
        import shutil
        self.collect_owned()
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

    def process_state(self, pid):
        try:
            raw = self.run(['ps', '-p', str(pid), '-o', 'lstart=,stat=,ppid=,comm='])
        except subprocess.CalledProcessError as error:
            if error.returncode == 1 and not (error.output or '').strip():
                try:
                    os.kill(pid, 0)  # Existence probe only; unreadable ps is not proof of death.
                except ProcessLookupError:
                    return None
                raise RuntimeError('Process identity unreadable; PID still exists: ' + str(pid)) from error
            raise
        fields = raw.split(None, 7)
        if len(fields) != 8:
            raise RuntimeError('Process identity unreadable: ' + str(pid))
        return dict(started=' '.join(fields[:5]), state=fields[5], parent=int(fields[6]), cmd=fields[7])

    def remember(self, pid, kind, expected_cmd=None, parent=None):
        if pid in [os.getpid(), self.resident.get('pid'), self.resident.get('daemonPid')]:
            raise RuntimeError('Protected identity cannot be owned')
        state = self.process_state(pid)
        if state is not None and expected_cmd is not None and state['cmd'] != expected_cmd:
            raise RuntimeError('Process changed during ownership capture; no signal: ' + str(pid))
        if state is not None and parent is not None and (state['parent'] != parent or not self.owned_alive(parent)):
            raise RuntimeError('Child ownership changed during capture; no signal: ' + str(pid))
        if state is not None and pid not in self.owned:
            self.owned[pid] = dict(state, kind=kind)

    def collect_owned(self):
        rows = self.process_rows()
        expected = str((self.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
        for pid, (_, cmd) in rows.items():
            if cmd == expected:
                self.remember(pid, 'qa', expected)  # Unique sandbox executable, never a name match.
        while True:
            added = False
            for pid, (parent, cmd) in rows.items():
                if pid not in self.owned and parent in self.owned:
                    self.remember(pid, 'child', cmd, parent)
                    added = added or pid in self.owned
            if not added:
                break

    def owned_alive(self, pid):
        current = self.process_state(pid)
        if current is None or current['state'].startswith('Z'):
            return False
        owned = self.owned[pid]
        if any(current[k] != owned[k] for k in ['started', 'cmd']):
            raise RuntimeError('Owned PID identity changed; no signal: ' + str(pid))
        return True

    def shutdown_wait(self, seconds):
        # Ignore latched cancellation/deadline here: they must not interrupt cleanup or mute checks.
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.guard_mute()
            time.sleep(min(.2, max(0, end - time.monotonic())))

    def terminate_owned(self, pid, runner=False):
        for sig, seconds in ([(signal.SIGINT, 45)] if runner else []) + [(signal.SIGTERM, 5), (signal.SIGKILL, 5)]:
            self.guard_mute()
            # Re-read PID/start/command immediately before EVERY individual signal, never killpg.
            if not self.owned_alive(pid):
                return
            os.kill(pid, sig)
            self.shutdown.append(dict(pid=pid, signal=int(sig), identity=self.owned[pid]))
            for _ in range(seconds):
                self.collect_owned()
                self.shutdown_wait(1)
                if self.child is not None:
                    self.child.poll()  # Reap the direct child without a blocking wait.
                if not self.owned_alive(pid):
                    return
        raise RuntimeError('Owned process still live after shutdown: ' + str(pid))

    def stop(self):
        errors = []
        # Runner, QA/descendant cleanup and final proof are independent, even if a leg fails.
        def attempt(action):
            try:
                action()
            except BaseException as error:
                errors.append(repr(error))
        attempt(self.collect_owned)
        if self.child is not None and self.child.poll() is None:
            if self.child.pid not in self.owned:
                errors.append('Runner identity was not captured at launch; no signal permitted')
            else:
                attempt(lambda: self.terminate_owned(self.child.pid, runner=True))
        attempt(self.collect_owned)  # Include QA launched while the runner was shutting down.
        for pid in list(self.owned):
            if self.child is None or pid != self.child.pid:
                attempt(lambda pid=pid: self.terminate_owned(pid))
        attempt(self.collect_owned)
        for pid in self.owned:
            def prove(pid=pid):
                if self.owned_alive(pid):
                    raise RuntimeError('Owned termination NOT_PROVEN: ' + str(pid))
            attempt(prove)
        if self.child is not None and self.child.poll() is None:
            errors.append('Runner termination NOT_PROVEN')
        if self.log:
            attempt(self.log.close)
        self.shutdown.append(dict(errors=errors, terminationProven=not errors))
        return not errors

    def restore_resident(self):
        if not self.resident:
            return
        if self.identity(self.resident['pid']) != self.resident['started']:
            raise RuntimeError('Cannot restore changed resident identity')
        if self.resident.get('restoreRequired'):
            self.settings(True)
            result = self.ax('read')
            if any('Show VoiceBar' in [n.get('title'), n.get('description')] for n in result['nodes']):
                try:
                    self.ax('show')
                except Exception as error:
                    self.resident.setdefault('reconciledActionErrors', []).append(repr(error))
                result = self.ax('read')  # Never retry a possibly applied Show.
            if not any('Hide VoiceBar for 1 hour' in [n.get('title'), n.get('description')] for n in result['nodes']):
                raise RuntimeError('Own Show unconfirmed')
            self.settings(False)
            snapshot = self.ax('read')
            if any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings' for n in snapshot['nodes']):
                raise RuntimeError('Settings reopened; restoration NOT_PROVEN, no user-owned close permitted')
            restored = self.surface(snapshot)
            initial = self.resident.get('initialSurface')
            self.resident['restoredSurface'] = restored
            self.save_resident()
            if not initial or not all(window in restored for window in initial):
                raise RuntimeError('Original resident surface restoration NOT_PROVEN')
            self.resident['restoreRequired'] = False
            self.resident['restored'] = True
        if self.resident.get('settingsOpened'):
            self.settings(False)
        if self.resident.get('initialHidden') and self.surface(self.ax('read')):
            raise RuntimeError('Initially hidden resident is now visible; restoration NOT_PROVEN')
        self.resident['identitiesUnchanged'] = self.identity(self.resident['daemonPid']) == self.resident['daemonStarted'] if 'daemonPid' in self.resident else True
        self.save_resident()
        if not self.resident['identitiesUnchanged']:
            raise RuntimeError('Resident daemon identity changed during gate')

    def export(self):
        return subprocess.call([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-results.py'),
                                'export', str(self.output), str(self.sandbox), '--scenario', self.scenario])

    def save(self, receipt):
        receipt['checks'] = self.checks
        receipt['shutdown'] = self.shutdown
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
