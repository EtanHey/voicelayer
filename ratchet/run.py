#!/usr/bin/env python3
"""Real app/daemon regressions. Scratch overlays only observe or remap paths."""
import argparse
import array
import fcntl
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import termios
import threading
import time
import wave

REPO = Path(__file__).resolve().parents[1]
ROWS = {
    "ndjson-partial-write": ("78a43fbb^1", "78a43fbb"),
    "socket-isolation": ("39a673b1^1", "313a959e"),
    "retranscribe-history-refresh": ("a2e25844^1", "a2e25844"),
    "recents-newest-after-retranscribe": ("2f2de18c^1", "2f2de18c"),
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

    def frames(self):
        with self.changed:
            return [json.loads(line) for line in b"".join(self.chunks).split(b"\n")[:-1] if line]

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


class Run:
    def __init__(self, ref, output, physical_root=False):
        self.ref, self.output = sha(ref), output
        output.write_text("")
        if physical_root:
            base = Path.home() / ".vlv"
            base.mkdir(exist_ok=True)
            if base.is_symlink() or base.resolve() != base:
                raise RuntimeError("ratchet requires a physical ~/.vlv root")
            self.root = Path(tempfile.mkdtemp(prefix="pdv-k-", dir=base))
        else:
            self.root = Path(tempfile.mkdtemp(prefix="vlr-", dir="/tmp"))
        self.procs, self.files, self.timers = [], [], []
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
        for name in ("state", "tmp", "recordings", "bin"):
            (self.root / name).mkdir()
        self.env.update({
            "SHELL": "/bin/sh", "VOICELAYER_SOCKET_PATH": str(self.root / "v.sock"),
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
        keys = ("VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH", "VOICELAYER_STATE_DIR", "VOICELAYER_TMP_ROOT",
                "QA_VOICE_SOCKET_PATH", "QA_VOICE_MCP_SOCKET_PATH", "RATCHET_RESIDENT")
        for key in keys + (("RATCHET_RECENTS_DEFAULTS",) if "RATCHET_RECENTS_DEFAULTS" in env else ()):
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

    def daemon(self, socket_path, pressure=False):
        argv = ["bun", "run", "src/mcp-server-daemon.ts"]
        if pressure:
            argv = ["bun", "run", "--preload", str(self.root / "pressure.ts"), "src/mcp-server-daemon.ts"]
        return self.launch(argv,
                           dict(self.env, VOICELAYER_SOCKET_PATH=str(socket_path), QA_VOICE_SOCKET_PATH=str(socket_path)), "daemon")

    def log(self, name="app"):
        path = self.root / (name + ".log")
        return path.read_text(errors="replace") if path.exists() else ""

    def transport_log(self, name="app"):
        return "\n".join(line for line in self.log(name).splitlines() if name != "app" or any(
            token in line for token in ("Bad JSON", "Client hello", "Server listening", "SOCKET_ISOLATION_REFUSED", "[ratchet-recents]"))) + "\n"

    def close(self):
        for timer in self.timers:
            timer.cancel()
        for proc in reversed(self.procs):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        for name in ("app", "daemon"):
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
    fixtures = prepare_recents(run) if row == "recents-newest-after-retranscribe" else None
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
    daemon = run.daemon(bridge, row == "ndjson-partial-write")
    # This daemon's unchanged rotator targets production logs after 60 s.
    # Keep the new row's daemon lifetime strictly below that first tick, even on failure.
    timer = threading.Timer(45, daemon.kill) if fixtures is not None else None
    if timer:
        run.timers.append(timer)
        timer.daemon = True
        timer.start()
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
        if fixtures is not None:
            return recents_scenario(run, captured, fixtures)
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
        if timer:
            timer.cancel()
            if daemon.poll() is None:
                daemon.terminate()
                daemon.wait(5)
        upstream.close()
        downstream.close()
        listener.close()
        thread.join(2)
        reverse_thread.join(2)


def instrument_recents(run):
    """Scratch-only input/observation/path seams; leave reducers byte-identical."""
    import difflib
    patches = []
    state = run.source / "flow-bar/Sources/VoiceBarUI/VoiceState.swift"
    original = state.read_text()
    needle = "    /// Recent transcription history with the newest item first."
    logger = '''    public func ratchetLogRecents(token: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = recentTranscriptionEntries.map { entry in
            ["path": entry.recordingPath ?? "", "created_at": entry.createdAt.map(formatter.string) ?? ""]
        }
        let payload: [String: Any] = ["token": token, "entries": entries,
            "pending": isHistoryRetranscriptionPending, "mode": mode.rawValue]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        NSLog("[ratchet-recents] %@", String(data: data, encoding: .utf8)!)
    }

'''
    assert original.count(needle) == 1, "Recents observation seam drifted"
    updated = original.replace(needle, logger + needle)
    start = updated.index("    public static func loadRecentTranscriptions()")
    end = updated.index("    private func startTranscriptionTimeout()", start)
    storage = updated[start:end]
    assert storage.count("UserDefaults.standard") == 4, "Recents path seam drifted"
    storage = storage.replace("UserDefaults.standard",
        'UserDefaults(suiteName: ProcessInfo.processInfo.environment["RATCHET_RECENTS_DEFAULTS"]!)!')
    updated = updated[:start] + storage + updated[end:]
    remap = 'UserDefaults(suiteName: ProcessInfo.processInfo.environment["RATCHET_RECENTS_DEFAULTS"]!)!'
    assert updated.replace(logger, "", 1).replace(remap, "UserDefaults.standard") == original
    server = run.source / "flow-bar/Sources/VoiceBar/SocketServer.swift"
    trigger = '''        if let type = dict["type"] as? String, type == "ratchet_history_retry" || type == "ratchet_recents_snapshot" {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if type == "ratchet_history_retry", let path = dict["audio_path"] as? String {
                    state.retranscribeHistoryEntry(recordingPath: path)
                } else if let token = dict["token"] as? String {
                    state.ratchetLogRecents(token: token)
                }
            }
            return
        }

'''
    before_server = server.read_text()
    server_needle = '        if let controlCommand = VoiceBarLocalControlCommand(payload: dict) {'
    assert before_server.count(server_needle) == 1, "History input seam drifted"
    run.output.with_suffix(".seams.json").write_text(json.dumps(dict(
        decision_code_unchanged=True, defaults_references_remapped=4,
        daemon_source_unchanged=True, trigger_method="VoiceState.retranscribeHistoryEntry")))
    for path, before, after in ((state, original, updated),
                               (server, before_server, before_server.replace(server_needle, trigger + server_needle))):
        path.write_text(after)
        patches.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
            fromfile="a/" + str(path.relative_to(run.source)), tofile="b/" + str(path.relative_to(run.source))))
    patch = "".join(patches)
    run.output.with_suffix(".overlay.patch").write_text(patch)
    run.overlay_hash = hashlib.sha256(patch.encode()).hexdigest()
    run.env["RATCHET_RECENTS_DEFAULTS"] = str(run.root / "state/recents")
    run.env["VOICEBAR_USER_DEFAULTS_SUITE"] = str(run.root / "state/app-defaults")


def prepare_recents(run):
    from datetime import datetime, timezone
    fixtures = []
    # Older missing recovery, existing older entry, existing head, newest cancelled capture.
    for day, status in ((18, "captured"), (19, "transcribed"), (20, "transcribed"), (21, "cancelled")):
        archive_id = f"2026-08-{day}T10-00-00-000Z-abcd1234"
        created = f"2026-08-{day}T10:00:00.000Z"
        directory = run.root / "recordings" / archive_id[:10] / archive_id
        directory.mkdir(parents=True)
        audio = directory / "audio.wav"
        with wave.open(str(audio), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\x10\x27\xf0\xd8" * 8000)
        metadata = dict(id=archive_id, created_at=created, source="voicebar", mode="ptt",
                        duration_ms=1000, raw_duration_ms=1000, transcribed_duration_ms=1000,
                        sample_rate=16000, channels=1, schema_version=3,
                        transcription_status=status, retention_policy="indefinite",
                        audio_sha256=hashlib.sha256(audio.read_bytes()).hexdigest())
        (directory / "metadata.json").write_text(json.dumps(metadata))
        fixtures.append(dict(path=str(audio), created_at=created))
    seeded = [fixtures[2], fixtures[1]]
    epoch = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
    entries = [dict(text="Synthetic seeded words " + str(i), recordingPath=item["path"],
                    createdAt=datetime.fromisoformat(item["created_at"].replace("Z", "+00:00")).timestamp() - epoch)
               for i, item in enumerate(seeded)]
    domain = Path(run.env["RATCHET_RECENTS_DEFAULTS"] + ".plist")
    domain.write_bytes(plistlib.dumps({"VoiceBar.recentTranscriptionEntries.v1": json.dumps(entries).encode()}))
    return fixtures


def recents_scenario(run, captured, fixtures):
    def send(payload):
        with connect(run.root / "v.sock") as client:
            client.sendall(json.dumps(payload).encode() + b"\n")

    def snapshot(token):
        send(dict(type="ratchet_recents_snapshot", token=token))
        found = []
        def observed():
            for line in run.log().splitlines():
                if "[ratchet-recents] " in line:
                    payload = json.loads(line.split("[ratchet-recents] ", 1)[1])
                    if payload["token"] == token:
                        found.append(payload)
                        return True
            return False
        wait(observed, 10)
        return found[-1]

    seed = snapshot("seed")
    assert seed["entries"] == [fixtures[2], fixtures[1]], "isolated synthetic Recents seed was not loaded"
    cases, failures = [], 0
    for index, (name, target, expected) in enumerate((
        ("newest-cancelled-recovery", fixtures[3], [fixtures[3], fixtures[2], fixtures[1]]),
        ("older-missing-recovery", fixtures[0], fixtures[::-1]),
        ("older-existing-retranscribe", fixtures[1], fixtures[::-1]))):
        directory = Path(target["path"]).parent
        original_status = json.loads((directory / "metadata.json").read_text())["transcription_status"]
        start = len(captured.frames())
        send(dict(type="ratchet_history_retry", audio_path=target["path"]))
        delivered = []
        def response_complete():
            frames = captured.frames()[start:]
            finals = [f for f in frames if f.get("type") == "transcription" and f.get("recording_path") == target["path"]]
            if finals and any(f.get("type") == "state" and f.get("state") == "idle" for f in frames):
                delivered[:] = finals
                return True
            return False
        wait(response_complete, 15)
        assert len(delivered) == 1, "missing/duplicate real-daemon History final"
        assert (directory / "voicelayer-transcript.txt").read_text() == "Recovered synthetic answer."
        assert json.loads((directory / "metadata.json").read_text())["transcription_status"] == "transcribed"
        current, attempts = [], 0
        def settled():
            nonlocal attempts
            attempts += 1
            current[:] = [snapshot(f"{index}-{attempts}")]
            return current[0]["mode"] == "idle" and not current[0]["pending"]
        wait(settled, 10)
        violations = recents_violations(current[0]["entries"], expected)
        failures += violations
        cases.append(dict(case=name, expected=expected, actual=current[0]["entries"], violations=violations,
                          original_transcription_status=original_status,
                          final_recording_created_at=delivered[0].get("recording_created_at"),
                          final_recording_is_latest=delivered[0].get("recording_is_latest"),
                          durable_transcript=True, durable_metadata=True))
    run.output.with_suffix(".recents.json").write_text(json.dumps(cases, indent=2) + "\n")
    domain = Path(run.env["RATCHET_RECENTS_DEFAULTS"] + ".plist")
    def persisted():
        try:
            entries = json.loads(plistlib.loads(domain.read_bytes())["VoiceBar.recentTranscriptionEntries.v1"])
            return any(entry["text"] == "Recovered synthetic answer." for entry in entries)
        except (OSError, ValueError, KeyError):
            return False
    wait(persisted, 10)
    run.defaults_plist_evidence = dict(plist_inside_root=domain.resolve().is_relative_to(run.root),
                                     seeded_read_verified=True, app_write_verified=True,
                                     plist_sha256=hashlib.sha256(domain.read_bytes()).hexdigest())
    return failures


def recents_violations(actual, expected):
    """Count missing/extra rows and position/age mismatches, never silently sort."""
    return abs(len(actual) - len(expected)) + sum(
        found != wanted for found, wanted in zip(actual, expected))


def resident_defaults_fingerprint():
    # Never save or print personal preference contents; preserve only comparison evidence.
    result = subprocess.run(["defaults", "read", "com.voicelayer.voicebar"], capture_output=True)
    if result.returncode != 0:
        if (result.returncode == 1 and not result.stdout and b"com.voicelayer.voicebar" in result.stderr
                and any(message in result.stderr for message in (b"not found", b"does not exist"))):
            return dict(exit_code=1, absent=True)
        raise RuntimeError("resident defaults probe failed; isolation evidence is missing")
    return dict(exit_code=result.returncode,
                sha256=hashlib.sha256(result.stdout + b"\0" + result.stderr).hexdigest())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--row", choices=ROWS)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for row in ([args.row] if args.row else ROWS):
        run, value, error, defaults_before = None, 1, None, None
        try:
            run = Run(args.ref, args.output / (row + ".build.log"),
                      physical_root=row == "recents-newest-after-retranscribe")
            if row == "socket-isolation":
                run.instrument()
            if row == "recents-newest-after-retranscribe":
                instrument_recents(run)
            run.build()
            if row == "recents-newest-after-retranscribe":
                defaults_before = resident_defaults_fingerprint()
                value = wire_row(run, row)
            else:
                value = isolation(run) if row == "socket-isolation" else wire_row(run, row)
        except Exception as failure:
            error = str(failure)
        finally:
            if run:
                try:
                    run.close()
                except Exception as failure:
                    value, error = 1, "cleanup failed: " + str(failure)
            if defaults_before is not None:
                try:
                    defaults_after = resident_defaults_fingerprint()
                except Exception:
                    defaults_after = dict(error="resident defaults probe failed")
                unchanged = defaults_before == defaults_after
                evidence = dict(resident_bundle="com.voicelayer.voicebar", before=defaults_before,
                                after=defaults_after, resident_defaults_unchanged=unchanged,
                                **getattr(run, "defaults_plist_evidence", {}))
                run.output.with_suffix(".defaults.json").write_text(json.dumps(evidence, indent=2) + "\n")
                if not unchanged:
                    value, error = 1, "resident bundle defaults changed during the isolated run"
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
