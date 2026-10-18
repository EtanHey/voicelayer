#!/usr/bin/env python3
"""Guard the native gate lifecycle; refuse UI mutation without causal Settings ownership."""
import argparse
import contextlib
import ctypes
import datetime
import errno
import fcntl
import hashlib
import hmac
import importlib.util
import json
import os
import pathlib
import re
import secrets
import shlex
import signal
import subprocess
import sys
import time


# Full PASS recorded 1488.545 s (earlier run 1504 s); keep 40 min for both broad suites.
# gate2246 run-01 reached 250 s of recording, before xcodebuild/recorder overhead.
SCENARIO_BUDGET_SECONDS = {'full': 2400, 'focused-338': 2400, 'gate2246': 600, 'hide1': 300}
# Whole owned-process cleanup (runner SIGINT 45 s + TERM/KILL legs + late children), bounded.
CLEANUP_BUDGET_SECONDS = 180

# The notch resident (2.2.45+) exposes one AX state group whose description is its visual
# state (VoiceBarNotchContract.accessibilityLabel(for:)): exactly 'VoiceBar' when idle,
# 'VoiceBar recording' / 'VoiceBar status' / 'VoiceBar teleprompter' when busy. The
# teleprompter renders spoken words as AX text, so only the structural state group (the
# first labelled node, an AXGroup) is idle evidence; arbitrary text never is.
RESIDENT_EXECUTABLE = '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'
NOTCH_IDLE_LABEL = 'VoiceBar'
BUSY_PREFIXES = ('Recording', 'Starting microphone', 'Stop recording', 'Cancel recording')
BUSY_TEXT = ('VoiceBar recording', 'VoiceBar status', 'VoiceBar teleprompter', 'Stop speaking',
             'VoiceBar launcher', 'VoiceBar history', 'Cancel transcription', 'Transcribing',
             'Agent speaking', 'Re-transcribing')
# Only mlx_lm.server and whisper-server server modes are allowlisted below.
# Exact labels only. Prefix/substring matching can detect busy state in memory but
# must never authorize retention of a spoken word or a dynamic status suffix.
AX_PUBLIC_LABELS = frozenset((NOTCH_IDLE_LABEL, 'VoiceBar launcher', 'VoiceBar history',
                              'Ready', 'Start voice recording', 'Re-transcribing stored audio',
                              'Re-transcribing…') + BUSY_PREFIXES + BUSY_TEXT)

# One key per supervisor process, kept only in memory. Receipts can correlate equal
# text within a run without exposing a reusable dictionary of short spoken words.
_REDACTION_KEY = secrets.token_bytes(32)
SUPERVISOR_LOCK_PATH = pathlib.Path('/tmp/voicebar-ui-e2e-supervisor-%d.lock' % os.getuid())


class OwnershipRace(RuntimeError):
    """A candidate's ownership could not be proven during a scan; it is skipped, never signalled."""


class _BsdInfo(ctypes.Structure):
    # struct proc_bsdinfo (sys/proc_info.h): 136 bytes, pbi_start_tvsec at 120, pbi_start_tvusec at 128.
    _fields_ = [('head', ctypes.c_uint8 * 120), ('start_tvsec', ctypes.c_uint64), ('start_tvusec', ctypes.c_uint64)]


_LIBSYSTEM = []


def _proc_pidinfo(pid):
    if not _LIBSYSTEM:
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        _LIBSYSTEM.append(library)
    info = _BsdInfo()
    size = _LIBSYSTEM[0].proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))  # PROC_PIDTBSDINFO
    if size != ctypes.sizeof(info):
        return 0, ctypes.get_errno()
    return (int(info.start_tvsec), int(info.start_tvusec)), 0


def kernel_birth(pid):
    """Kernel start time (seconds, microseconds) of a live PID; None only on ESRCH; else fail closed."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise RuntimeError('Process identity unreadable: invalid pid %r' % (pid,))
    birth, error = _proc_pidinfo(pid)
    if birth:
        return birth
    if error == errno.ESRCH:
        return None
    raise RuntimeError('Process identity unreadable: %d (errno %d)' % (pid, error))


def birth_text(birth):
    return '%d.%06d' % tuple(birth)


def parse_birth(started):
    try:
        seconds, micros = str(started).split('.')
        return int(seconds), int(micros)
    except ValueError:
        return None


def token_digest(token):
    return hashlib.sha256(token.encode()).hexdigest()[:32]


def register_owned(registry, token, kind, pid, birth):
    """Append one acknowledged launch: the runner calls this in the child before exec."""
    line = json.dumps(dict(token=token_digest(token), kind=kind, pid=pid, birth=list(birth))) + '\n'
    fd = os.open(str(registry), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def redacted(text):
    tag = hmac.new(_REDACTION_KEY, text.encode(), hashlib.sha256).hexdigest()[:8]
    return '<redacted len=%d hmac-sha256=%s>' % (len(text), tag)


class SupervisorActiveError(RuntimeError):
    pass


@contextlib.contextmanager
def supervisor_lock():
    # One per-user host lock, independent of TMPDIR/output roots. Never unlink it:
    # replacing the inode could admit a contender while another run holds its lock.
    path = SUPERVISOR_LOCK_PATH
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        raise SupervisorActiveError('Cannot open supervisor lock: %s (%s)' % (path, error)) from None
    with os.fdopen(fd, 'r+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SupervisorActiveError('Another supervisor run is active; lock ' + str(path)) from None
        # PID is diagnostic only. The kernel releases the lock even on SIGKILL, so
        # a stale dead owner's file is reclaimed without PID-reuse guessing.
        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()) + '\n')
        lock.flush()
        yield


def ax_text_receipt(text):
    return text if text in AX_PUBLIC_LABELS or text == '' else redacted(text)


def ax_receipt(nodes):
    return [dict({k: n[k] for k in ['role', 'identifier', 'frame'] if k in n},
                 **{k: ax_text_receipt(n[k]) for k in ['title', 'description', 'value'] if k in n})
            for n in nodes]


def permission_receipt(permission):
    prompts = permission.get('prompts')
    if prompts is not None:
        if not isinstance(prompts, list):
            raise RuntimeError('Permission prompt inventory malformed')
        retained = []
        for prompt in prompts:
            labels = prompt.get('labels')
            if not isinstance(labels, list) or not all(isinstance(x, str) for x in labels):
                raise RuntimeError('Permission prompt labels unreadable')
            text = ' '.join(labels).casefold()
            kind = next((kind for kind, terms in [
                ('microphone', ('microphone',)), ('accessibility', ('accessibility',)),
                ('input-monitoring', ('input monitoring', 'input-monitoring', 'monitor input')),
                ('screen-recording', ('screen recording', 'screen-recording', 'record your screen', 'screen and system audio'))
            ] if any(term in text for term in terms)), 'unknown')
            owner = prompt.get('owner') or prompt.get('processName') or 'unknown'
            if not isinstance(owner, str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', owner):
                owner = redacted(str(owner))
            retained.append(dict(owner=owner,
                                 kind=kind, labels=[redacted(x) for x in labels]))
        prompts = retained
    return dict(axTrusted=permission.get('axTrusted') is True, prompts=prompts)


def ax_nodes(ax_tree):
    # A bare string is unstructured text: it can match busy text, never the notch group.
    return [dict(value=x) if isinstance(x, str) else x for x in ax_tree]


def node_labels(node):
    return [x for key in ['title', 'description', 'value'] if (x := node.get(key))]


def notch_idle(nodes):
    labelled = [n for n in nodes if node_labels(n)]
    return bool(labelled) and labelled[0].get('role') == 'AXGroup' and node_labels(labelled[0]) == [NOTCH_IDLE_LABEL] \
        and labelled[0].get('description') == NOTCH_IDLE_LABEL


def unsafe_reasons(busy_children, fresh_locks, ax_tree):
    nodes = ax_nodes(ax_tree)
    labels = [x for n in nodes for x in node_labels(n)]
    reasons = []
    if busy_children:
        reasons.append('unallowlisted child process(es) under resident daemon: '
                       + repr(list(busy_children)))
    if fresh_locks:
        reasons.append('fresh session lock(s) (<300s): ' + repr(list(fresh_locks)))
    busy = [x for x in labels if x.startswith(BUSY_PREFIXES) or any(t in x for t in BUSY_TEXT)]
    if busy:
        reasons.append('AX shows busy resident: ' + repr([ax_text_receipt(x) for x in busy]))
    # Require positive AX evidence. A collapsed/empty tree is UNKNOWN, never idle.
    elif not notch_idle(nodes):
        reasons.append('no positive idle AX evidence; observed ' + repr(ax_receipt(nodes)))
    return reasons


def safe_to_hide(busy_children, fresh_locks, ax_tree):
    return not unsafe_reasons(busy_children, fresh_locks, ax_tree)


def note(message, log=None):
    line = '[supervisor] ' + message
    print(line, file=sys.stderr, flush=True)
    if log is not None:
        with open(log, 'a') as file:
            file.write(line + '\n')


def wait_until_safe(host):
    for attempt in range(3):
        if host.preconditions():
            return
        if attempt < 2:
            host.wait(120)
    raise RuntimeError('Resident preconditions unknown/unsafe after bounded wait/recheck; no capture interrupted')


def require_supervisor(output, environment):
    proof = json.loads((output / 'supervisor-authority.json').read_text())
    birth = proof.get('birth')
    if (proof.get('pid') != os.getppid() or not proof.get('token')
            or proof['token'] != environment.get('VOICEBAR_UIE2E_SUPERVISOR_TOKEN')
            or not isinstance(birth, list) or len(birth) != 2
            or kernel_birth(proof['pid']) != tuple(birth)):
        raise ValueError('Native launch requires its live parent safety supervisor')
    # The authenticated identity, carried into run_suite; never re-derived from a later getppid().
    return dict(pid=proof['pid'], birth=tuple(birth))


def supervise(host):
    receipt = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'suiteExit': None,
               'exportExit': None, 'cleanupErrors': []}
    initial = None
    run_started = False
    try:
        initial = host.muted()
        receipt['initialMuted'] = initial
        host.set_mute(True)
        host.prepare_resident()
        host.start()
        run_started = True
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
            reason = getattr(host, 'mute_retention_reason', None)
            if reason:
                receipt['muteRetentionReason'] = reason
            else:
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
        if receipt.get('error') or receipt['cleanupErrors']:
            where = getattr(host, 'output', None)
            getattr(host, 'note', note)('FAILED: ' + '; '.join(([receipt['error']] if receipt.get('error') else []) + receipt['cleanupErrors'])
                 + ('; receipt ' + str(where / 'operator-state.json') if where else ''))
    if receipt['suiteExit'] is not None:
        try:
            receipt['exportExit'] = host.export()
        except BaseException as error:
            receipt['error'] = repr(error)
        host.save(receipt)
    launched = run_started or getattr(host, 'runner_launch_attempted', False) or getattr(host, 'child', None) is not None
    if receipt['cleanupErrors']:
        code = 1
    elif receipt.get('error') and not launched:
        code = 2
    elif receipt.get('error') or receipt['suiteExit'] != 0 or receipt['exportExit'] != 0:
        code = 1
    elif receipt.get('muteRetentionReason') and receipt.get('muteRetained'):
        code = 3
    elif receipt['ownedTerminationProven'] and receipt.get('muteRestored'):
        code = 0
    else:
        code = 1
    receipt.update(exitCode=code, verdict={0: 'PASS', 3: 'PASS', 1: 'FAIL', 2: 'PREFLIGHT_REFUSED'}[code])
    host.save(receipt)
    mute = ('retained-by-design' if code == 3 else 'retained' if receipt.get('muteRetained')
            else 'restored' if receipt.get('muteRestored') else 'unknown')
    print(f"verdict={receipt['verdict']} exit={code} mute={mute} "
          f"receipt={pathlib.Path(getattr(host, 'output', '.')) / 'operator-state.json'}", flush=True)
    return code


class NativeHost:
    def __init__(self, output, scenario):
        self.output, self.scenario = output, scenario
        self.repo = pathlib.Path(__file__).resolve().parent.parent
        self.sandbox = pathlib.Path((output / 'sandbox-path.txt').read_text().strip())
        self.child = None
        self.resident = {}
        self.preflight = {}
        # Opened before any precondition so a pre-launch STOP can never leave an empty log.
        self.preflight_log = output / 'supervisor-preflight.log'
        self.preflight_log.touch()
        self.checks = []
        self.cancelled = []
        self.deadline = None
        self.log = None
        self.owned = {}
        self.ownership_races = []
        self.cleanup_notes = []
        self.token = None
        self.registry = output / 'owned-registrations.jsonl'
        # Launchd-launched apps count only if born after this supervisor began (exact path AND birth).
        now = time.time()
        self.launch_birth = (int(now), int(now % 1 * 10**6))
        self.shutdown = []
        self.runner_launch_attempted = False
        self.mute_retention_reason = None

    def run(self, args):
        return subprocess.check_output(args, text=True, timeout=15).strip()

    def note(self, message):
        note(message, self.preflight_log)

    def permissions(self):
        # The helper prints its JSON and exits 2 on a prompt/untrusted AX; parse it either way.
        helper = str(self.output / 'voicebar-ui-e2e-permissions')
        result = subprocess.run([helper], capture_output=True, text=True, timeout=15, check=False)
        try:
            parsed = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError('Permission helper unreadable: exit %d stdout %s stderr %s'
                               % (result.returncode, redacted(result.stdout), redacted(result.stderr))) from None
        # Sanitize at ingestion, before either checks[] or refuse_permissions/note sees it.
        return result.returncode, permission_receipt(parsed)

    def refuse_permissions(self, code, permissions):
        if permissions.get('axTrusted') is not True or permissions.get('prompts') != [] or code != 0:
            message = ('STOP: permission prompt or unreadable AX; never dismiss/grant (exit %d, axTrusted=%r, '
                       'prompts=%s)' % (code, permissions.get('axTrusted'), json.dumps(permissions.get('prompts'))))
            self.note(message)
            raise RuntimeError(message)

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
        if mode != 'read':
            self.refuse_settings_mutation(mode)
        self.guard_mute()
        if self.identity(self.resident['pid']) != self.resident['started']:
            raise RuntimeError('Resident identity changed; no AX action permitted')
        args = [str(self.output / 'voicebar-ui-e2e-resident'), str(self.resident['pid']), mode]
        result = json.loads(self.run(args))
        return result

    def read_resident_ax(self):
        try:
            return self.ax('read')
        except Exception as error:
            # Helper failures may embed stdout/AX text. Never propagate that payload
            # into supervise()'s operator receipt or its FAILED log line.
            raise RuntimeError('Resident AX read failed: %s %s' %
                               (type(error).__name__, ax_text_receipt(str(error)))) from None

    def guard_mute(self):
        if not self.muted():
            self.set_mute(True)
        if not self.muted():
            raise RuntimeError('Shutdown mute guard unconfirmed')

    def retire_settings_claim(self):
        # A physical window ID is neither causality nor a lifecycle generation.
        if self.resident.get('settingsOpened') or 'settingsWindowId' in self.resident:
            self.resident['settingsRestoreRequired'] = True
            self.resident['restored'] = False
        self.resident['settingsOpened'] = False
        self.resident.pop('settingsWindowId', None)
        self.save_resident()

    def refuse_settings_mutation(self, mode):
        self.retire_settings_claim()
        self.resident['settingsOwnership'] = 'NOT_PROVEN'
        self.resident['refusedSettingsAction'] = mode
        self.save_resident()
        raise RuntimeError('Settings causal/lifecycle ownership NOT_PROVEN; native mutation refused before dispatch')

    def settings_state(self):
        # Retire before reading: even an unreadable/absent snapshot cannot renew a lease.
        self.retire_settings_claim()
        result = self.read_resident_ax()
        opened = any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings'
                     for n in result['nodes'])
        if opened:
            raise RuntimeError('Settings ownership NOT_PROVEN; preserve possibly user-owned window')
        return opened

    def settings(self, opened):
        if self.settings_state() == opened:
            return
        # The installed resident has no causal, generation-bound ownership protocol.
        # Refuse before any possibly applied action; matching/new IDs cannot repair that.
        self.refuse_settings_mutation('open' if opened else 'close')

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
        (self.output / 'resident-visibility.json').write_text(
            json.dumps(dict(self.resident, preflight=self.preflight), indent=2) + '\n')

    def process_rows(self):
        rows = {}
        for line in self.run(['ps', '-axo', 'pid=,ppid=,comm=']).splitlines():
            pid, parent, cmd = line.strip().split(None, 2)
            rows[int(pid)] = (int(parent), cmd)
        return rows

    def identity(self, pid):
        return self.run(['ps', '-p', str(pid), '-o', 'lstart='])

    def child_args(self, pid):
        # Resident children can be short-lived; one that exited between the rows read and
        # this read is not the daemon, so the precondition rechecks instead of aborting.
        try:
            return self.run(['ps', '-p', str(pid), '-o', 'args='])
        except subprocess.CalledProcessError as error:
            try:
                os.kill(pid, 0)  # Existence probe only.
            except ProcessLookupError:
                self.note('resident child %d exited before its args were read; ignored' % pid)
                return None
            except PermissionError:
                pass
            raise RuntimeError('Resident child args unreadable; PID still exists: %d (ps exit %d, output %r)'
                               % (pid, error.returncode, error.output)) from error

    def idle_daemon_child(self, pid, executable):
        # Only direct daemon children qualify. These servers persist while idle.
        # HTTP whisper-server transcription creates
        # no child process: AX transcribing state and fresh session locks cover it.
        name = pathlib.Path(executable).name
        python = r'(?:Python|python(?:3(?:\.\d+)?)?)'
        if name != 'whisper-server' and not re.fullmatch(python, name):
            return False
        try:
            argv = shlex.split(self.child_args(pid) or '')
        except ValueError:
            return False
        if not argv:
            return False
        if name == 'whisper-server':
            return pathlib.Path(argv[0]).name == name and any(
                flag == '--port' and value.isdecimal() and 0 < int(value) < 65536
                for flag, value in zip(argv[1:], argv[2:]))
        return bool(re.fullmatch(python, pathlib.Path(argv[0]).name)) and (
            argv[1:3] == ['-m', 'mlx_lm.server'] or
            len(argv) > 1 and pathlib.Path(argv[1]).name == 'mlx_lm.server')

    def resident_inventory(self, attempt):
        rows = self.process_rows()
        residents = sorted(p for p, (_, cmd) in rows.items() if cmd == RESIDENT_EXECUTABLE)
        related = set(residents) | ({self.resident['pid']} if self.resident.get('pid') in rows else set())
        while True:
            extended = related | {p for p, (parent, _) in rows.items() if parent in related}
            if extended == related:
                break
            related = extended
        attempt.update(residentPids=residents, residentCount=len(residents),
                       processRows={str(p): list(rows[p]) for p in sorted(related)})
        self.preflight.update(residentPids=residents, residentCount=len(residents))
        return rows

    def preconditions(self):
        attempt = dict(safe=False, residentPids=None, residentCount=None, daemonPids=None,
                       daemonCount=None, processRows={})
        self.resident.setdefault('preconditions', []).append(attempt)
        try:
            rows = self.resident_inventory(attempt)
            # Save an unsafe observation before any identity/args/AX reads can fail.
            self.save_resident()
            pid = self.resident['pid']
            residents = attempt['residentPids']
            if residents != [pid]:
                raise RuntimeError('Exactly one installed resident required on recheck; never launch/replace one '
                                   '(expected [%d], observed %d %r)' % (pid, len(residents), residents))
            observed = self.identity(pid)
            attempt['residentStarted'] = observed
            if observed != self.resident['started']:
                raise RuntimeError('Resident identity changed; no action permitted (pid %d expected started %r, observed %r)'
                                   % (pid, self.resident['started'], observed))
            children = attempt['residentChildren'] = {}
            for p, (parent, _) in sorted(rows.items()):
                if parent == pid:
                    children[p] = self.child_args(p)
            daemons = [p for p, args in children.items() if args is not None and 'mcp-server-daemon.ts' in args]
            attempt.update(daemonPids=daemons, daemonCount=len(daemons))
            if len(daemons) != 1:
                self.note('precondition failed: expected exactly one mcp-server-daemon.ts child of resident %d; '
                          'observed %d %r; resident children %r' % (pid, len(daemons), daemons, children))
                return False
            daemon = daemons[0]
            identity = self.identity(daemon)
            attempt['daemonStarted'] = identity
            if 'daemonPid' in self.resident and (daemon != self.resident['daemonPid'] or identity != self.resident['daemonStarted']):
                raise RuntimeError('Resident daemon identity changed; no action permitted (expected pid %r started %r, '
                                   'observed pid %d started %r)' % (self.resident['daemonPid'], self.resident['daemonStarted'],
                                                                    daemon, identity))
            self.resident.update(daemonPid=daemon, daemonStarted=identity)
            descendants = {daemon}
            while True:
                extended = descendants | {p for p, (parent, _) in rows.items() if parent in descendants}
                if extended == descendants:
                    break
                descendants = extended
            busy = [p for p in sorted(descendants - {daemon})
                    if rows[p][0] != daemon or not self.idle_daemon_child(p, rows[p][1])]
            locks = []
            attempt.update(capturePids=busy, freshLocks=locks)
            for path in pathlib.Path('/tmp').glob('voicelayer-session-*.lock'):
                try:
                    if time.time() - path.stat().st_mtime < 300:
                        locks.append(path.name)
                except FileNotFoundError:
                    pass
            nodes = self.read_resident_ax()['nodes']
            attempt.update(axNodes=ax_receipt(nodes), axLabels=[ax_text_receipt(x) for n in nodes for x in node_labels(n)],
                           notchIdle=notch_idle(nodes))
            reasons = unsafe_reasons(['%d %s' % (p, pathlib.Path(rows[p][1]).name) for p in busy], locks, nodes)
            for reason in reasons:
                self.note('precondition failed: ' + reason)
            attempt['safe'] = not reasons
            return attempt['safe']
        except BaseException as error:
            attempt.update(safe=False, error=repr(error))
            self.note('precondition failed: ' + repr(error))
            raise
        finally:
            self.save_resident()

    def prepare_resident(self):
        attempt = dict(safe=False, processRows={})
        self.preflight['prepareInventory'] = attempt
        try:
            code, permission = self.permissions()
            self.checks.append(dict(phase='preflight', permissionsExit=code, permissions=permission))
            self.refuse_permissions(code, permission)
            self.resident_inventory(attempt)
            self.save_resident()
            residents = attempt['residentPids']
            if len(residents) != 1:
                raise RuntimeError('Exactly one installed resident required; never launch/replace one (observed %d %r)'
                                   % (len(residents), residents))
            self.resident = dict(pid=residents[0], started=self.identity(residents[0]), restoreRequired=False,
                                 settingsOpened=False)
            self.save_resident()
            snapshot = self.read_resident_ax()
            attempt['axNodes'] = ax_receipt(snapshot['nodes'])
            self.resident['initialSurface'] = self.surface(snapshot)
            if not self.resident['initialSurface']:
                raise RuntimeError('A shown resident surface is required; no native visibility mutation permitted')
            # Leave the installed resident shown: no open/close/Hide/Show action.
            self.resident.update(visibilityPolicy='leave-shown', initialHidden=False)
            self.save_resident()
            wait_until_safe(self)
            attempt['safe'] = True
        except BaseException as error:
            attempt.update(safe=False, error=repr(error))
            self.note('prepare failed: ' + repr(error))
            raise
        finally:
            self.save_resident()

    def start(self):
        wait_until_safe(self)
        if self.resident.get('visibilityPolicy') == 'leave-shown':
            self.verify_shown_resident()
        else:
            self.settings(False)
            if self.read_resident_ax()['screenWindows']:
                raise RuntimeError('Resident window remains on screen after own Hide')
        self.check()
        subprocess.run([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-results.py'), 'configure',
                        str(self.output), str(self.sandbox / 'VoiceBarQA.app'), str(self.sandbox),
                        '--scenario', self.scenario], check=True, timeout=120)
        token = self.token = secrets.token_hex(24)
        with (self.output / 'supervisor-authority.json').open('x') as file:
            json.dump(dict(pid=os.getpid(), birth=list(kernel_birth(os.getpid())), token=token), file)
        env = dict(os.environ, VOICEBAR_UIE2E_SUPERVISOR_TOKEN=token,
                   VOICEBAR_UIE2E_RESIDENT_SNAPSHOT=str(self.output / 'resident-visibility.json'))
        self.log = (self.output / 'supervisor.log').open('w')
        self.deadline = time.monotonic() + SCENARIO_BUDGET_SECONDS[self.scenario]
        # Popen may launch then fail before returning a handle. Polling cannot close this gap.
        self.runner_launch_attempted = True
        self.child = subprocess.Popen([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-run.py'),
                                      str(self.output), '--scenario', self.scenario], env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        self.remember(self.child.pid, 'runner')

    def poll(self):
        return self.child.poll() if self.child is not None else None

    def check(self):
        import shutil
        self.collect_owned()
        code, permissions = self.permissions()
        free = shutil.disk_usage('/System/Volumes/Data').free
        muted = self.muted()
        self.checks.append(dict(muted=muted, freeBytes=free, permissionsExit=code, permissions=permissions))
        if not muted or free < (10 if self.child else 15) * 1024**3:
            raise RuntimeError('Mute lost or disk threshold crossed (muted=%r, freeBytes=%d)' % (muted, free))
        self.refuse_permissions(code, permissions)
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
            # lstart is local time: pin locale and zone so a DST change cannot fake a reuse.
            raw = self.run(['env', 'LC_ALL=C', 'TZ=UTC0', 'ps', '-p', str(pid), '-o', 'lstart=,stat=,ppid=,comm='])
        except subprocess.CalledProcessError as error:
            if error.returncode == 1 and not (error.output or '').strip():
                try:
                    os.kill(pid, 0)  # Existence probe only; unreadable ps is not proof of death.
                except ProcessLookupError:
                    return None
                raise RuntimeError('Process identity unreadable; PID still exists: ' + str(pid)) from error
            raise RuntimeError('Process identity unreadable: %d (ps exit %d, output %r)'
                               % (pid, error.returncode, error.output)) from error
        fields = raw.split(None, 7)
        if len(fields) != 8:
            raise RuntimeError('Process identity unreadable: ' + str(pid))
        # Birth identity is the kernel's microsecond start time (lstart is only whole seconds),
        # read after ps and again; a change across the reads is never one identity.
        before = self.kernel_birth(pid)
        if before is None:
            return None
        after = self.kernel_birth(pid)
        if after != before:
            raise OwnershipRace('Process identity changed during read; no signal: %d (%r then %r)' % (pid, before, after))
        return dict(started=birth_text(before), lstart=' '.join(fields[:5]), state=fields[5],
                    parent=int(fields[6]), cmd=fields[7])

    def kernel_birth(self, pid):
        return kernel_birth(pid)

    def remember(self, pid, kind, expected_cmd=None, parent=None, expected_started=None, born_after=None):
        if pid in [os.getpid(), self.resident.get('pid'), self.resident.get('daemonPid')]:
            raise RuntimeError('Protected identity cannot be owned')
        state = self.process_state(pid)
        if state is not None and expected_started is not None and state['started'] != expected_started:
            raise OwnershipRace('Registered PID is a different process; no signal: %d (registered birth %s, observed %s)'
                                % (pid, expected_started, state['started']))
        if state is not None and born_after is not None and (parse_birth(state['started']) or (0, 0)) < born_after:
            raise OwnershipRace('Exact-path process predates this gate; not owned: %d (born %s)' % (pid, state['started']))
        if state is not None and expected_cmd is not None and state['cmd'] != expected_cmd:
            raise OwnershipRace('Process changed during ownership capture; no signal: %d (expected cmd %r, observed %r)'
                               % (pid, expected_cmd, state['cmd']))
        if state is not None and parent is not None:
            parent_alive = self.owned_alive(parent) if state['parent'] == parent else None
            if not parent_alive:
                raise OwnershipRace('Child ownership changed during capture; no signal: %d (expected parent %d, '
                                   'observed parent %d, parentAlive=%r)' % (pid, parent, state['parent'], parent_alive))
        if state is not None and pid not in self.owned:
            self.owned[pid] = dict(state, kind=kind)

    def adopt(self, pid, kind, expected_cmd=None, parent=None, **identity):
        # A process that exits, is reparented or reused mid-scan is unprovable, not fatal:
        # skip it (never signal it) and keep scanning. Launch completeness stays NOT_PROVEN.
        try:
            self.remember(pid, kind, expected_cmd, parent, **identity)
        except OwnershipRace as error:
            if len(self.ownership_races) < 50:
                self.ownership_races.append(dict(pid=pid, kind=kind, error=str(error)))

    def registered(self):
        # Acknowledged launches: the runner appends PID + kernel birth in each child before exec,
        # so a child reparented (or in its own session) before any scan is still ours.
        if not self.token or not self.registry.exists():
            return []
        digest, rows = token_digest(self.token), []
        for line in self.registry.read_text().splitlines():
            try:
                row = json.loads(line)
                pid, birth = row['pid'], row['birth']
                if row['token'] != digest or not isinstance(pid, int) or pid <= 1:
                    continue
                rows.append((pid, str(row['kind']), birth_text(birth)))
            except (ValueError, KeyError, TypeError):
                continue  # A torn final line from a killed writer proves nothing.
        return rows

    def collect_owned(self):
        for pid, kind, started in self.registered():
            if pid not in self.owned:
                self.adopt(pid, 'registered-' + kind, expected_started=started)
        rows = self.process_rows()
        # Unique run-local executables, never a name match. XCTest launches its runner app
        # through launchd, so no PPID chain from our runner reaches it (run-03 PID 47300).
        unique = {str((self.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve()): 'qa',
                  str((self.output / 'DerivedData/Build/Products/Debug/VoiceBarUIE2ETests-Runner.app/Contents'
                       '/MacOS/VoiceBarUIE2ETests-Runner').resolve()): 'xctest-runner'}
        for pid, (_, cmd) in rows.items():
            if cmd in unique and pid not in self.owned:
                self.adopt(pid, unique[cmd], cmd, born_after=self.launch_birth)
        while True:
            added = False
            for pid, (parent, cmd) in rows.items():
                if pid not in self.owned and parent in self.owned:
                    self.adopt(pid, 'child', cmd, parent)
                    added = added or pid in self.owned
            if not added:
                break

    def owned_alive(self, pid):
        owned = self.owned[pid]
        if self.child is not None and pid == self.child.pid:
            # Our own unreaped child: its PID cannot be reused, whatever it exec'd into.
            # Once poll() reaps it, it is never signalled again (run-03 PID 46884).
            alive = self.child.poll() is None
            if alive:
                try:  # Receipt only: record the runner's exec transitions.
                    current = self.process_state(pid)
                    if current and owned.get('cmd') and current['cmd'] != owned['cmd'] \
                            and current['cmd'] not in owned.setdefault('execs', []):
                        owned['execs'].append(current['cmd'])
                except Exception:
                    pass
            return alive
        if owned.get('retired'):
            return False
        current = self.process_state(pid)
        if current is None or current['state'].startswith('Z'):
            return False
        # Identity is PID + start time. exec keeps both (framework Python's bin/python3 stub,
        # xcrun's xcodebuild shim); a reused PID always has a new start time.
        if current['started'] != owned['started']:
            owned['retired'] = dict(reason='pid-reused', observed=current)
            self.note('owned PID %d exited and was reused (owned %r, observed %r); never signalled'
                      % (pid, {k: owned.get(k) for k in ['started', 'cmd', 'parent']}, current))
            return False
        if current['cmd'] != owned['cmd'] and current['cmd'] not in owned.setdefault('execs', []):
            owned['execs'].append(current['cmd'])
        return True

    def cleanup_note(self, message):
        if message not in self.cleanup_notes:
            self.cleanup_notes.append(message)

    def cleanup_step(self, label, action):
        # Mute, discovery and wait failures are recorded (termination then stays NOT_PROVEN and
        # mute retained) but never stop signalling an already provable target.
        try:
            action()
        except BaseException as error:
            self.cleanup_note(label + ': ' + repr(error))

    def shutdown_wait(self, seconds):
        # Ignore latched cancellation/deadline here: they must not interrupt cleanup or mute checks.
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.cleanup_step('mute guard', self.guard_mute)
            time.sleep(min(.2, max(0, end - time.monotonic())))

    def terminate_owned(self, pid, runner=False, deadline=None):
        for sig, seconds in ([(signal.SIGINT, 45)] if runner else []) + [(signal.SIGTERM, 5), (signal.SIGKILL, 5)]:
            self.cleanup_step('mute guard', self.guard_mute)
            # Re-read PID/birth immediately before EVERY individual signal, never killpg. A residual
            # exit-and-recycle between this read and kill() remains possible for non-child PIDs.
            if not self.owned_alive(pid):
                return
            os.kill(pid, sig)
            self.shutdown.append(dict(pid=pid, signal=int(sig), identity=self.owned[pid]))
            for _ in range(seconds):
                if deadline is not None and time.monotonic() > deadline:
                    raise RuntimeError('Cleanup deadline reached; owned termination NOT_PROVEN: ' + str(pid))
                self.cleanup_step('discovery', self.collect_owned)
                self.cleanup_step('wait', lambda: self.shutdown_wait(1))
                if self.child is not None:
                    self.child.poll()  # Reap the direct child without a blocking wait.
                if not self.owned_alive(pid):
                    return
        raise RuntimeError('Owned process still live after shutdown: ' + str(pid))

    def stop(self):
        errors = []
        self.mute_retention_reason = None
        self.cleanup_notes = []
        deadline = time.monotonic() + CLEANUP_BUDGET_SECONDS
        # Runner, QA/descendant cleanup and final proof are independent, even if a leg fails.
        def attempt(action):
            try:
                action()
            except BaseException as error:
                errors.append(repr(error))
        attempt(self.collect_owned)
        handled = set()
        if self.child is not None and self.child.poll() is None:
            # The unreaped Popen handle is the runner's identity proof, even if ps missed it.
            self.owned.setdefault(self.child.pid, dict(kind='runner', source='popen-handle'))
            handled.add(self.child.pid)
            attempt(lambda: self.terminate_owned(self.child.pid, runner=True, deadline=deadline))
        # Fixed-point drain: anything adopted while another PID was shutting down is terminated too.
        while True:
            attempt(self.collect_owned)  # Include QA launched while the runner was shutting down.
            pending = [pid for pid in self.owned if pid not in handled
                       and (self.child is None or pid != self.child.pid)]
            if not pending:
                break
            if time.monotonic() > deadline:
                errors.append('Cleanup deadline reached; owned termination NOT_PROVEN: %r' % pending)
                break
            for pid in pending:
                handled.add(pid)
                attempt(lambda pid=pid: self.terminate_owned(pid, deadline=deadline))
        for pid in self.owned:
            def prove(pid=pid):
                if self.owned_alive(pid):
                    raise RuntimeError('Owned termination NOT_PROVEN: ' + str(pid))
            attempt(prove)
        if self.child is not None and self.child.poll() is None:
            errors.append('Runner termination NOT_PROVEN')
        errors.extend(self.cleanup_notes)
        if self.runner_launch_attempted or self.child is not None:
            # The runner registers its own launches before exec, but processes those launch in turn
            # (xcodebuild's tools, launchd-started apps beyond the exact paths) are only discovered.
            reason = 'Launch completeness NOT_PROVEN; discovered subset is not all-owned proof'
            errors.append(reason)
        if self.log:
            attempt(self.log.close)
        if (self.runner_launch_attempted or self.child is not None) and errors == [reason]:
            self.mute_retention_reason = reason
        self.shutdown.append(dict(errors=errors, terminationProven=not errors))
        return not errors

    def verify_shown_resident(self):
        if self.identity(self.resident['pid']) != self.resident['started']:
            raise RuntimeError('Resident identity changed during shown gate')
        if ('daemonPid' in self.resident and
                self.identity(self.resident['daemonPid']) != self.resident['daemonStarted']):
            raise RuntimeError('Resident daemon identity changed during shown gate')
        current = self.surface(self.read_resident_ax())
        initial = self.resident.get('initialSurface')
        if not initial or not all(window in current for window in initial):
            raise RuntimeError('Original shown resident surface NOT_PROVEN; no Settings mutation permitted')
        self.resident['shownUnchanged'] = True
        self.resident['identitiesUnchanged'] = True
        self.save_resident()

    def restore_resident(self):
        if not self.resident:
            return
        if self.resident.get('visibilityPolicy') == 'leave-shown':
            self.resident['shownUnchanged'] = False
            self.save_resident()
            self.verify_shown_resident()
            return
        required = any(self.resident.get(key) for key in
                       ['restoreRequired', 'settingsRestoreRequired', 'settingsActionPending',
                        'settingsOpened', 'settingsWindowId'])
        if required:
            self.resident['restored'] = False
            self.save_resident()
        if self.identity(self.resident['pid']) != self.resident['started']:
            raise RuntimeError('Cannot restore changed resident identity')
        self.settings_state()  # Always check, including prepare failures before Hide.
        if self.resident.get('settingsRestoreRequired') or self.resident.get('settingsActionPending'):
            # A lost action response may precede delayed application. Absence and a completed
            # no-op process cleanup cannot discharge it. Retain the obligation for recovery.
            raise RuntimeError('Settings restoration NOT_PROVEN; pending action/retired claim requires recovery')
        if self.resident.get('restoreRequired'):
            self.settings(True)
            result = self.read_resident_ax()
            if any('Show VoiceBar' in [n.get('title'), n.get('description')] for n in result['nodes']):
                try:
                    self.ax('show')
                except Exception as error:
                    self.resident.setdefault('reconciledActionErrors', []).append(repr(error))
                result = self.read_resident_ax()  # Never retry a possibly applied Show.
            if not any('Hide VoiceBar for 1 hour' in [n.get('title'), n.get('description')] for n in result['nodes']):
                raise RuntimeError('Own Show unconfirmed')
            self.settings(False)
            snapshot = self.read_resident_ax()
            if any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings' for n in snapshot['nodes']):
                raise RuntimeError('Settings reopened; restoration NOT_PROVEN, no user-owned close permitted')
            restored = self.surface(snapshot)
            initial = self.resident.get('initialSurface')
            self.resident['restoredSurface'] = restored
            self.save_resident()
            if not initial or not all(window in restored for window in initial):
                raise RuntimeError('Original resident surface restoration NOT_PROVEN')
        if self.resident.get('settingsOpened'):
            self.settings(False)
        if self.resident.get('initialHidden') and self.surface(self.read_resident_ax()):
            raise RuntimeError('Initially hidden resident is now visible; restoration NOT_PROVEN')
        self.resident['identitiesUnchanged'] = False
        self.save_resident()
        if (self.identity(self.resident['pid']) != self.resident['started'] or
                ('daemonPid' in self.resident and
                 self.identity(self.resident['daemonPid']) != self.resident['daemonStarted'])):
            raise RuntimeError('Resident daemon identity changed during gate')
        self.resident['identitiesUnchanged'] = True
        if required:
            self.resident['restoreRequired'] = False
            self.resident['restored'] = True
        self.save_resident()

    def export(self):
        return subprocess.call([sys.executable, str(self.repo / 'scripts/voicebar-ui-e2e-results.py'),
                                'export', str(self.output), str(self.sandbox), '--scenario', self.scenario],
                               timeout=300)

    def save(self, receipt):
        receipt['checks'] = self.checks
        receipt['shutdown'] = self.shutdown
        receipt['preflight'] = self.preflight
        # Before/after identity of every owned PID (execs, reuse retirements) and skipped races.
        receipt['owned'] = {str(pid): owned for pid, owned in self.owned.items()}
        receipt['ownershipRaces'] = self.ownership_races
        (self.output / 'operator-state.json').write_text(json.dumps(receipt, indent=2) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--scenario', default='full', choices=['full', 'hide1', 'gate2246', 'focused-338'])
    args = parser.parse_args(argv)
    try:
        # Acquire before host construction or reading/changing workstation mute;
        # retain through cleanup, mute restoration and receipt export.
        with supervisor_lock():
            host = NativeHost(args.output.resolve(), args.scenario)
            # Latch signals through cleanup; restoration cannot be interrupted by a second signal.
            for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
                signal.signal(sig, lambda number, frame: host.cancelled.append(number))
            return supervise(host)
    except SupervisorActiveError as error:
        try:
            note('PREFLIGHT_REFUSED: ' + str(error), args.output.resolve() / 'supervisor-preflight.log')
        except OSError as log_error:
            # note() already wrote the refusal to stderr. Missing/unwritable output
            # must not turn a safe admission refusal into a traceback/exit 1.
            note('Preflight log unavailable: ' + str(log_error))
        return 2


if __name__ == '__main__':
    sys.exit(main())
