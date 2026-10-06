#!/usr/bin/env python3
"""Real app/daemon regressions. Scratch overlays only observe or remap paths."""
import argparse
import array
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import termios
import threading
import time
import wave

REPO = Path(__file__).resolve().parents[1]
ROWS = {
    "voice-ask-lock-suspends-timeout": ("a2e25844fd98be78293ff3133122a6df0b0a50c8",
                                         "7677d52e5045970485f0dd5c141f8c069f66e9d9"),
    "ndjson-partial-write": ("78a43fbb^1", "78a43fbb"),
    "socket-isolation": ("39a673b1^1", "313a959e"),
    "retranscribe-history-refresh": ("a2e25844^1", "a2e25844"),
}


def command(args, **kwargs):
    return subprocess.check_output(args, **kwargs).decode().strip()


def sha(ref):
    return command(["git", "-C", str(REPO), "rev-parse", ref + "^{commit}"])


def wait(predicate, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.05)
    raise RuntimeError("deadline expired; missing binary/socket/event is FAIL")


def connect(path):
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(30)
    client.connect(str(path))
    return client


class Wire:
    def __init__(self):
        self.chunks, self.changed = [], threading.Condition()
        self.last = time.monotonic()

    def feed(self, raw):
        with self.changed:
            self.chunks.append(raw)
            self.last = time.monotonic()
            self.changed.notify_all()

    def archive(self, path, timeout=10, quiet=1):
        deadline, cap = time.monotonic() + timeout, time.monotonic() + timeout + quiet + 1
        with self.changed:
            while True:
                complete = b"".join(self.chunks).split(b"\n")[:-1]
                frames = [json.loads(line) for line in complete if line]
                observed = any(f.get("type") == "archive_metadata_updated" and f.get("recording_path") == path for f in frames)
                now = time.monotonic()
                if observed and now - self.last >= quiet:
                    return frames, True, not b"".join(self.chunks).split(b"\n")[-1]
                if now >= cap or (not observed and now >= deadline):
                    return frames, observed, False
                self.changed.wait(min(.05, max(0, cap - now)))


def pressure_evidence(chunks, frame_bytes, queued, stall, buffer):
    ends, offset = [], 0
    for chunk in chunks:
        offset += len(chunk)
        ends.append(offset)
    split, start = 0, 0
    for line in b"".join(chunks).splitlines(keepends=True):
        end = start + len(line)
        split += int(any(start < edge < end for edge in ends))
        start = end
    maximum = max(map(len, chunks), default=0)
    exercised = bool(frame_bytes and split and 0 < maximum < max(frame_bytes)
                     and queued >= buffer and stall >= .5 and 0 < buffer < max(frame_bytes))
    return dict(exercised=exercised, expected_frame_bytes=frame_bytes, recv_chunks=len(chunks),
                max_recv_chunk=maximum, split_frames=split, queued_bytes_before_read=queued,
                reader_stall_seconds=stall, receive_buffer_bytes=buffer)


def require_pressure(evidence):
    if not evidence["exercised"]:
        raise RuntimeError("pressure not exercised")


class DaemonLifetime:
    """Parent-side SIGKILL deadline, armed through child teardown."""
    def __init__(self, proc, seconds=45, started=None):
        if not 0 < seconds <= 45:
            raise ValueError('daemon lifetime cap must be at most 45 seconds')
        self.proc, self.started = proc, started if started is not None else time.monotonic()
        self.deadline = self.started + seconds
        self.expired = threading.Event()
        self.elapsed = None
        self.timer = threading.Timer(max(0, self.deadline - time.monotonic()), self._expire)
        self.timer.daemon = True
        self.timer.start()

    def _expire(self):
        if self.proc.poll() is None:
            self.expired.set()
            self.proc.kill()

    def check(self):
        if time.monotonic() >= self.deadline:
            self._expire()
        if self.expired.is_set():
            raise RuntimeError('daemon lifetime cap exhausted')

    def budget(self, seconds):
        self.check()
        return max(.001, min(seconds, self.deadline - time.monotonic()))

    def wait(self, predicate, timeout):
        end = time.monotonic() + self.budget(timeout)
        while time.monotonic() < end:
            self.check()
            if predicate():
                return
            time.sleep(min(.05, self.budget(.05)))
        self.check()
        raise RuntimeError('deadline expired; missing binary/socket/event is FAIL')

    def finish(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=max(.001, min(2, self.deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                self._expire() if time.monotonic() >= self.deadline else self.proc.kill()
                self.proc.wait(1)
        if self.elapsed is None:
            self.elapsed = time.monotonic() - self.started
        self.timer.cancel()
        self.timer.join(1)


class Run:
    def __init__(self, ref, output):
        self.ref, self.output = sha(ref), output
        output.write_text("")
        parent = Path.home() / ".vlv"
        parent.mkdir(mode=0o700, exist_ok=True)
        if parent.is_symlink() or parent.resolve() != parent:
            raise RuntimeError("scratch parent must be a physical absolute path")
        self.root = Path(tempfile.mkdtemp(prefix="pdv-", dir=parent))
        self.procs, self.files, self.caps = [], [], []
        self.source = self.root / "source"
        self.overlay_hash = None
        try:
            self.setup(output)
        except BaseException:
            self.close()
            raise

    def setup(self, output):
        subprocess.run(["git", "-C", str(REPO), "worktree", "add", "--detach", "--quiet",
                        str(self.source), self.ref], check=True,
                       env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
        # Dependencies belong to the target checkout, not an injected module mock.
        with output.open("a") as log:
            subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=self.source, check=True,
                           stdout=log, stderr=subprocess.STDOUT)
        self.env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "PATH") if k in os.environ}
        for name in ("state", "tmp", "recordings", "bin", "home"):
            (self.root / name).mkdir()
        self.env.update({
            "HOME": str(self.root / "home"), "SHELL": "/bin/sh", "VOICELAYER_SOCKET_PATH": str(self.root / "v.sock"),
            "VOICELAYER_MCP_SOCKET_PATH": str(self.root / "m.sock"),
            "QA_VOICE_SOCKET_PATH": str(self.root / "v.sock"),
            "QA_VOICE_MCP_SOCKET_PATH": str(self.root / "m.sock"),
            "VOICELAYER_STATE_DIR": str(self.root / "state"),
            "VOICELAYER_TMP_ROOT": str(self.root / "tmp"),
            "VOICELAYER_CONTROL_LAYER_BASE": str(self.root / "state/control"),
            "VOICELAYER_PROCESSING_SETTINGS_PATH": str(self.root / "state/processing.json"),
            "QA_VOICE_RECORDINGS_DIR": str(self.root / "recordings"),
            "QA_VOICE_STT_VOCABULARY_PATH": str(self.root / "vocab.json"),
            "QA_VOICE_MCP_PID_PATH": str(self.root / "m.pid"),
            "QA_VOICE_MCP_HEARTBEAT_PATH": str(self.root / "m.heartbeat"),
            "QA_VOICE_RECORDING_STATE_PATH": str(self.root / "state/recording.json"),
            "QA_VOICE_RETAINED_RECORDING_PATH": str(self.root / "tmp/retained.wav"),
            "QA_VOICE_DISABLE_FLAG_PATH": str(self.root / "tmp/disabled"),
            "QA_VOICE_STT_POLISH": "off", "QA_VOICE_STT_BACKEND": "whisper",
            "QA_VOICE_WHISPER_MODEL": str(self.root / "model.bin"),
            "VOICELAYER_ALLOW_ORPHAN_DAEMON": "1", "VOICEBAR_QA_PRESERVE_OVERRIDES": "1",
            "VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE": "1", "VOICEBAR_QA_SKIP_HOTKEY": "1",
            "VOICEBAR_QA_SKIP_PERMISSION_PROMPTS": "1", "VOICEBAR_QA_SKIP_LS_REGISTER": "1",
            "QA_VOICEBAR_CAPTURE_OFFSCREEN": "1",
            "VOICEBAR_USER_DEFAULTS_SUITE": "ratchet." + self.root.name,
            "RATCHET_RESIDENT": str(self.root / "resident.sock"),
        })
        (self.root / "model.bin").touch()
        stub = self.root / "bin/whisper-cli"
        stub.write_text("#!/bin/sh\nprintf 'Recovered synthetic answer.\\n'\n")
        stub.chmod(0o700)
        self.env["PATH"] = str(self.root / "bin") + ":" + self.env["PATH"]

    def instrument(self):
        policy = self.source / "flow-bar/Sources/VoiceBar/SocketBindingPolicy.swift"
        patch = ""
        if policy.exists():
            original = policy.read_text()
            needle = '["/tmp/voicelayer.sock", "/tmp/voicelayer-mcp.sock"]'
            assert original.count(needle) == 1, "protected-path seam drifted"
            updated = original.replace(needle, needle[:-1] + ', ProcessInfo.processInfo.environment["RATCHET_RESIDENT"]!]')
            policy.write_text(updated)
            import difflib
            patch = "".join(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
                              fromfile="a/" + str(policy.relative_to(self.source)),
                              tofile="b/" + str(policy.relative_to(self.source))))
        self.output.with_suffix(".overlay.patch").write_text(patch)
        self.overlay_hash = hashlib.sha256(patch.encode()).hexdigest()

    def build(self):
        with self.output.open("a") as log:
            subprocess.run(["swift", "build", "--package-path", "flow-bar", "--product", "VoiceBar", "-j", "2"],
                           cwd=self.source, stdout=log, stderr=log, check=True)
        path = command(["swift", "build", "--package-path", "flow-bar", "--show-bin-path"], cwd=self.source)
        # Outside a repo/bundle: app cannot autolaunch a second, sanitized daemon.
        self.binary = self.root / "VoiceBar"
        shutil.copy2(Path(path) / "VoiceBar", self.binary)
        self.binary_hash = hashlib.sha256(self.binary.read_bytes()).hexdigest()

    def launch(self, argv, env=None, logname="app"):
        env = env or self.env
        for key in ("VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH", "VOICELAYER_STATE_DIR", "VOICELAYER_TMP_ROOT",
                    "QA_VOICE_SOCKET_PATH", "QA_VOICE_MCP_SOCKET_PATH", "RATCHET_RESIDENT"):
            path = Path(env[key]).resolve()
            if not path.is_relative_to(self.root.resolve()) or len(str(path).encode()) >= 100:
                raise RuntimeError("refusing unsafe/oversized isolation path")
        log = (self.root / (logname + ".log")).open("w")
        self.files.append(log)
        proc = subprocess.Popen(argv, env=env, cwd=self.source, stdout=log, stderr=log)
        self.procs.append(proc)
        return proc

    def app(self, env=None):
        return self.launch([str(self.binary)], env)

    def daemon(self, socket_path, pressure=False, logname="daemon"):
        argv = ["bun", "run", "src/mcp-server-daemon.ts"]
        if pressure:
            argv = ["bun", "run", "--preload", str(self.root / "pressure.ts"), "src/mcp-server-daemon.ts"]
        started = time.monotonic()
        proc = self.launch(argv, dict(self.env, VOICELAYER_SOCKET_PATH=str(socket_path),
                                     QA_VOICE_SOCKET_PATH=str(socket_path)), logname)
        cap = DaemonLifetime(proc, started=started)
        self.caps.append(cap)
        return cap

    def log(self, name="app"):
        path = self.root / (name + ".log")
        return path.read_text(errors="replace") if path.exists() else ""

    def transport_log(self, name="app"):
        return "\n".join(line for line in self.log(name).splitlines() if name != "app" or any(
            token in line for token in ("Bad JSON", "Client hello", "Server listening", "SOCKET_ISOLATION_REFUSED"))) + "\n"

    def close(self):
        for cap in self.caps:
            cap.finish()
        for proc in reversed(self.procs):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        for name in ("app", "daemon", "daemon-stop", "daemon-unlock"):
            self.output.with_suffix("." + name + ".log").write_text(self.transport_log(name))
        for log in self.files:
            log.close()
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        try:
            listing = command(["git", "-C", str(REPO), "worktree", "list", "--porcelain"], env=env)
            if any(Path(line[9:]).resolve() == self.source.resolve() for line in listing.splitlines()
                   if line.startswith("worktree ")):
                subprocess.run(["git", "-C", str(REPO), "worktree", "remove", "--force", str(self.source)], check=True, env=env)
        finally:
            shutil.rmtree(self.root)


def isolation(run):
    failures, cases = 0, []
    for case in ("plain", "case", "parent-symlink", "socket-symlink"):
        base = run.root / "resident.sock"
        candidate = base
        if case == "case":
            candidate = run.root / "RESIDENT.SOCK"
        if case == "parent-symlink":
            alias = run.root / "alias"
            alias.symlink_to(run.root, target_is_directory=True)
            candidate = alias / base.name
        listener_path = candidate if case == "case" else base
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(listener_path))
        listener.listen()
        listener.settimeout(5)
        if case == "socket-symlink":
            candidate = run.root / "linked.sock"
            candidate.symlink_to(base)
        inode = candidate.lstat().st_ino
        proc = run.app(dict(run.env, VOICELAYER_SOCKET_PATH=str(candidate), QA_VOICE_SOCKET_PATH=str(candidate)))
        try:
            wait(lambda: proc.poll() is not None or "Server listening" in run.log())
            refused = proc.poll() == 1 and "SOCKET_ISOLATION_REFUSED" in run.log()
            intact = candidate.exists() and candidate.lstat().st_ino == inode
            failures += int(not (refused and intact))
            cases.append(dict(case=case, refused=refused, intact=intact, exit_code=proc.poll()))
            run.output.with_suffix("." + case + ".app.log").write_text(run.transport_log())
            if intact:
                with connect(candidate):
                    accepted, _ = listener.accept()
                    accepted.close()
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(5)
            listener.close()
            for path in set((candidate, listener_path, base)):
                if path.exists() or path.is_symlink():
                    path.unlink()
    assert "ratchet." in run.env["VOICEBAR_USER_DEFAULTS_SUITE"]
    run.output.with_suffix(".isolation.json").write_text(json.dumps(cases, indent=2))
    return failures


def wire_row(run, row):
    (run.root / "vocab.json").write_text(json.dumps({"entries": []}))
    run.app()
    app_path = run.root / "v.sock"
    wait(lambda: app_path.exists())
    bridge = run.root / "bridge.sock"
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(bridge))
    pressure = row == "ndjson-partial-write"
    if pressure:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    listener.listen()
    if pressure:
        (run.root / "pressure.ts").write_text(
            'import {broadcast,isConnected} from ' + json.dumps(str(run.source / 'src/socket-client')) + ';\n'
            'const timer=setInterval(()=>{if(!isConnected()) return; clearInterval(timer);\n'
            'for(let i=0;i<2;i++) {const frame={type:"client_hello",role:"ratchet-"+i,pid:process.pid,\n'
            'accepts_commands:true,payload:"אבג — …".repeat(80000)};\n'
            'console.error("[ratchet] frame_bytes="+Buffer.byteLength(JSON.stringify(frame)+"\\n")); broadcast(frame as any);}\n'
            'setTimeout(()=>{broadcast({type:"client_hello",role:"ratchet-2",pid:process.pid,accepts_commands:true} as any);\n'
            'console.error("[ratchet] sent=3");},1000);},100);\n')
    listener.settimeout(30)
    run.daemon(bridge, row == "ndjson-partial-write")
    upstream, _ = listener.accept()
    if pressure:
        upstream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    upstream.settimeout(20)
    downstream = connect(app_path)
    captured, errors, pressure_state = Wire(), [], {}

    def forward():
        try:
            # Real daemon serializer and socket.write meet a stalled kernel buffer.
            if pressure:
                # Observe the full kernel queue while the sender cannot drain it.
                start = time.monotonic()
                time.sleep(.5)
                queued = array.array("i", [0])
                fcntl.ioctl(upstream, termios.FIONREAD, queued, True)
                pressure_state.update(queued=queued[0], stall=time.monotonic() - start,
                                      buffer=upstream.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
            while True:
                raw = upstream.recv(4093)
                if not raw:
                    break
                downstream.sendall(raw)
                captured.feed(raw)
        except Exception as error:
            errors.append(str(error))

    def reverse():
        try:
            while True:
                raw = downstream.recv(4096)
                if not raw:
                    break
                upstream.sendall(raw)
        except Exception:
            pass  # teardown; forward and row deadlines detect missing traffic

    thread = threading.Thread(target=forward, daemon=True)
    reverse_thread = threading.Thread(target=reverse, daemon=True)
    thread.start()
    reverse_thread.start()
    try:
        wait(lambda: (run.root / "m.sock").exists())
        if row == "ndjson-partial-write":
            try:
                wait(lambda: all("role: ratchet-" + str(i) + "," in run.log() for i in range(3)), 10)
            except RuntimeError:
                pass  # evaluate the real Bad JSON and missing handled-frame counts below
            assert "[ratchet] sent=3" in run.log("daemon"), "pressure fixture did not emit frames"
            bad_json = run.log().count("[VoiceBar] Bad JSON from client")
            missing = sum("role: ratchet-" + str(i) + "," not in run.log() for i in range(3))
            sizes = [int(line.split("frame_bytes=", 1)[1]) for line in run.log("daemon").splitlines()
                     if line.startswith("[ratchet] frame_bytes=")]
            evidence = pressure_evidence(captured.chunks, sizes, pressure_state.get("queued", 0),
                                        pressure_state.get("stall", 0), pressure_state.get("buffer", 0))
            run.output.with_suffix(".wire.json").write_text(json.dumps({
                "sent_frames": 3, "handled_frames": 3 - missing, "bad_json": bad_json,
                "wire_bytes": sum(map(len, captured.chunks)), "errors": errors, "pressure": evidence}))
            require_pressure(evidence)
            return bad_json + missing
        archive_id = "2026-08-20T10-11-12-000Z-abcd1234"
        directory = run.root / "recordings" / archive_id[:10] / archive_id
        directory.mkdir(parents=True)
        audio = directory / "audio.wav"
        with wave.open(str(audio), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\x10\x27\xf0\xd8" * 8000)
        audio_hash = hashlib.sha256(audio.read_bytes()).hexdigest()
        agent = b"ID3\x01\x02\x03"
        (directory / "agent-audio.mp3").write_bytes(agent)
        (directory / "agent-transcript.txt").write_text("Synthetic question?")
        metadata = dict(id=archive_id, created_at="2026-08-20T10:11:12.000Z", source="voice_ask",
                        mode="ptt", silence_mode="thoughtful", duration_ms=1000, raw_duration_ms=1000,
                        transcribed_duration_ms=1000, sample_rate=16000, channels=1, schema_version=3,
                        transcription_status="captured", retention_policy="indefinite", backend=None,
                        audio_sha256=audio_hash, user_audio_sha256=audio_hash,
                        agent_audio_sha256=hashlib.sha256(agent).hexdigest(),
                        artifacts={"agent_audio": "agent-audio.mp3", "agent_transcript": "agent-transcript.txt",
                                   "user_audio": "audio.wav", "user_transcript": "voicelayer-transcript.txt"})
        (directory / "metadata.json").write_text(json.dumps(metadata))
        payload = json.dumps(dict(jsonrpc="2.0", id=42, method="tools/call", params={
            "name": "voice_ask", "arguments": {"retranscribe_archive_id": archive_id}})).encode()
        with connect(run.root / "m.sock") as mcp:
            mcp.sendall(b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
            with mcp.makefile("rb") as stream:
                header = stream.readline()
                length = int(header.decode().strip().removeprefix("Content-Length: "))
                if stream.readline() != b"\r\n":
                    raise RuntimeError("missing MCP header delimiter")
                response = json.loads(stream.read(length))
            assert not response["result"].get("isError"), response
        wait(lambda: (directory / "voicelayer-transcript.txt").exists())
        frames, observed, quiet = captured.archive(str(audio.resolve()))
        matches = [f for f in frames if f.get("type") == "archive_metadata_updated"
                   and f.get("recording_path") == str(audio.resolve())]
        assert (directory / "voicelayer-transcript.txt").read_text() == "Recovered synthetic answer."
        assert json.loads((directory / "metadata.json").read_text())["transcription_status"] == "transcribed"
        run.output.with_suffix(".wire.json").write_text(json.dumps({
            "archive_updates": len(matches), "durable_transcript": True, "durable_metadata": True,
            "transcription_events": sum(f.get("type") == "transcription" for f in frames),
            "event_observed": observed, "quiet_period_complete": quiet, "quiet_seconds": 1}))
        return int(not observed or not quiet or len(matches) != 1 or any(f.get("type") == "transcription" for f in frames))
    finally:
        upstream.close()
        downstream.close()
        listener.close()
        thread.join(2)
        reverse_thread.join(2)


def lock_violations(case):
    if (not case['lock_ack'] or case['pcm_seconds'] <= 0 or case['held_seconds'] < 21
            or not case['completed'] or case['ending'] not in ('stop', 'unlock')):
        raise RuntimeError('lock evidence missing or incomplete')
    if not case['ended_before_release'] and (case['pcm_seconds'] < 15 or not case['ending_ack']):
        raise RuntimeError('lock evidence did not exercise pre-speech silence')
    return int(case['ended_before_release'])


def lock_row(run):
    # Device/TTS executable fixtures only; product source and VAD remain untouched.
    for name, fixture in [('rec', 'fixture-rec.py'), ('python3', 'fixture-tts.py')]:
        path = run.root / 'bin' / name
        path.write_text('#!' + sys.executable + '\n' + (REPO / 'ratchet' / fixture).read_text())
        path.chmod(0o700)
    player = run.root / 'bin/afplay'
    player.write_text('#!/bin/sh\nexit 0\n')
    player.chmod(0o700)
    run.env.update(VOICELAYER_TEST_FAKE_REC='1',
                   VOICELAYER_TEST_FAKE_REC_BIN=str(run.root / 'bin/rec'),
                   RATCHET_PYTHON=sys.executable,
                   RATCHET_REC_RECEIPT=str(run.root / 'rec.json'))
    (run.root / 'vocab.json').write_text('{"entries": []}')
    fixture_names = ('fixture-rec.py', 'fixture-tts.py', 'lock-client.ts')
    run.output.with_suffix('.fixtures.json').write_text(json.dumps({
        name: hashlib.sha256((REPO / 'ratchet' / name).read_bytes()).hexdigest()
        for name in fixture_names}, indent=2) + '\n')
    client_script = run.source / 'ratchet-lock-client.ts'
    shutil.copy2(REPO / 'ratchet/lock-client.ts', client_script)
    cases = []
    for ending in ('stop', 'unlock'):
        case = lock_case(run, ending, client_script)
        cap = run.caps[-1]
        cap.check()
        case.update(daemon_lifetime_seconds=cap.elapsed, daemon_cap_seconds=45, daemon_cap_expired=cap.expired.is_set())
        cases.append(case)
        run.output.with_suffix('.lock.json').write_text(json.dumps(cases, indent=2) + '\n')
    return sum(lock_violations(case) for case in cases)


def lock_case(run, ending, client_script):
    # Only this case's daemon is alive; the watchdog includes startup and teardown.
    for path in (run.root / 'v.sock', run.root / 'm.sock'):
        path.unlink(missing_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(run.env['VOICELAYER_SOCKET_PATH'])
    listener.listen()
    cap = run.daemon(run.root / 'v.sock', logname='daemon-' + ending)
    listener.settimeout(cap.budget(5))
    bar = None
    try:
        bar, _ = listener.accept()
    except BaseException:
        cap.finish()
        listener.close()
        raise
    bar.settimeout(.1)
    frames, faults, done = [], [], threading.Event()

    def receive():
        pending = b''
        try:
            while not done.is_set():
                try:
                    raw = bar.recv(65536)
                except socket.timeout:
                    continue
                if not raw:
                    raise RuntimeError('daemon disconnected')
                pending += raw
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if line:
                        frames.append((time.monotonic(), json.loads(line)))
        except Exception as error:
            if not done.is_set():
                faults.append(str(error))

    reader = threading.Thread(target=receive, daemon=True)
    reader.start()
    try:
        cap.wait(lambda: (run.root / 'm.sock').exists(), 3)
        result_path = run.root / ('sdk-' + ending + '.json')
        rec_path = run.root / 'rec.json'
        rec_path.unlink(missing_ok=True)
        client = run.launch(['bun', str(client_script), str(result_path)], logname='sdk-' + ending)
        def has_frame(predicate):
            if faults or client.poll() not in (None, 0):
                raise RuntimeError('missing lock boundary: ' + repr(faults) + run.log('sdk-' + ending))
            return any(predicate(frame) for _, frame in frames)
        cap.wait(lambda: has_frame(lambda f: f.get('type') == 'state' and f.get('state') == 'recording'), 6)
        command_id = 'lock-' + ending
        bar.sendall((json.dumps(dict(cmd='set_recording_hold', engaged=True, id=command_id)) + '\n').encode())
        cap.wait(lambda: has_frame(lambda f: f.get('type') == 'ack' and f.get('id') == command_id), 2)
        ack = next(f for _, f in frames if f.get('type') == 'ack' and f.get('id') == command_id)
        if ack.get('outcome') != 'accept':
            raise RuntimeError('lock evidence: command not accepted: ' + repr(ack))
        locked = time.monotonic()
        # Exceed input deadline (5), outer watchdog (20), and pre-speech silence (15).
        while time.monotonic() - locked < 21:
            cap.check()
            if faults:
                raise RuntimeError('lock evidence: disconnected boundary')
            time.sleep(.05)
        release = time.monotonic()
        ended = [(when, frame) for when, frame in frames if when < release
                 and frame.get('type') == 'state' and frame.get('state') in ('idle', 'transcribing')
                 and frame.get('source') != 'playback']
        before_release = json.loads(rec_path.read_text())
        early = bool(ended or result_path.exists() or before_release['stopped'])
        end_ack = None
        if not early:
            cmd = dict(cmd='stop' if ending == 'stop' else 'set_recording_hold', id='end-' + ending)
            if ending == 'unlock':
                cmd['engaged'] = False
            bar.sendall((json.dumps(cmd) + '\n').encode())
            cap.wait(lambda: has_frame(lambda f: f.get('type') == 'ack' and f.get('id') == cmd['id']), 5)
            end_ack = next(f for _, f in frames if f.get('type') == 'ack' and f.get('id') == cmd['id'])
            if end_ack.get('outcome') != 'accept':
                raise RuntimeError('lock evidence: ending not accepted')
        cap.wait(lambda: result_path.exists(), 12)
        client.wait(cap.budget(1))
        cap.check()
        result = json.loads(result_path.read_text())
        if client.returncode or result.get('isError'):
            raise RuntimeError('lock evidence: SDK request failed')
        pcm = json.loads(rec_path.read_text())
        case = dict(ending=ending, lock_ack=True, held_seconds=release - locked,
                    ended_before_release=early, completed=result['completed'],
                    pcm_seconds=pcm['pcm_seconds'], recorder_seconds=pcm['elapsed_seconds'],
                    ending_ack=end_ack is not None, accepted_lock=ack, accepted_ending=end_ack,
                    early_end_seconds=ended[0][0] - locked if ended else None)
        return case
    finally:
        done.set()
        cap.finish()
        reader.join(.2)
        bar.close()
        listener.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--row", choices=ROWS)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for row in ([args.row] if args.row else ROWS):
        run, value, error = None, 1, None
        try:
            run = Run(args.ref, args.output / (row + ".build.log"))
            if row == "socket-isolation":
                run.instrument()
            run.build()
            value = (isolation(run) if row == "socket-isolation" else
                     lock_row(run) if row == "voice-ask-lock-suspends-timeout" else wire_row(run, row))
        except Exception as failure:
            error = str(failure)
        finally:
            if run:
                try:
                    run.close()
                    for cap in run.caps:
                        cap.check()
                except Exception as failure:
                    value, error = 1, "cleanup failed: " + str(failure)
        result = dict(row=row, kind="behavior", value=value, ceiling=0,
                      status="PASS" if value == 0 else "FAIL", bug_sha=sha(ROWS[row][0]),
                      fix_sha=sha(ROWS[row][1]), measured_sha=sha(args.ref), error=error,
                      overlay_sha256=run.overlay_hash if run else None,
                      app_binary_sha256=getattr(run, "binary_hash", None))
        print(json.dumps(result), flush=True)
        results.append(result)
        (args.output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    return int(any(row["status"] != "PASS" for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
