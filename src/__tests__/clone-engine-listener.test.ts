import { expect, it } from "bun:test";
import { mkdtempSync, readFileSync, existsSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// Exercise the real Python CLI's bind-before-create boundary with uvicorn/app
// replaced by HTTP fixtures. No Qwen dependencies, synthesis, port 8880 or mic.
const fakeRuntime = String.raw`
import importlib.util, json, os, socket, sys, types
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
spec = importlib.util.spec_from_file_location('engine', sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
marker = sys.argv[2]
port = int(sys.argv[3])
def create(*args, **kwargs):
    Path(marker + '.created').write_text('fake app constructed')
    return object()
class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({'status':'ok', 'pid':os.getpid(), 'model_loaded':False}).encode())
    def log_message(self, *args): pass
def run(app, fd, log_level):
    server = HTTPServer(('127.0.0.1', 0), Health, bind_and_activate=False)
    server.socket.close()
    server.socket = socket.fromfd(fd, socket.AF_INET, socket.SOCK_STREAM)
    Path(marker).write_text(str(server.socket.getsockname()[1]))
    server.serve_forever()
engine.create_app = create
sys.modules['uvicorn'] = types.SimpleNamespace(run=run)
sys.argv = ['fake-engine', '--host', '127.0.0.1', '--port', str(port)]
engine.main()
`;

it("kernel reservation rejects a competing engine before app creation, keeping the first healthy", async () => {
  const root = mkdtempSync(join(tmpdir(), "v10-engine-"));
  const entry = join(import.meta.dir, "../tts_daemon.py");
  const first = Bun.spawn(["python3", "-B", "-c", fakeRuntime, entry, join(root, "first"), "0"], {
    env: {...process.env, HOME: root}, stdout: "pipe", stderr: "pipe",
  });
  try {
    const deadline = Date.now() + 8000;
    while (!existsSync(join(root, "first")) && first.exitCode === null && Date.now() < deadline) await Bun.sleep(10);
    if (!existsSync(join(root, "first"))) throw new Error(await new Response(first.stderr).text());
    expect(existsSync(join(root, "first"))).toBe(true);
    const port = Number(readFileSync(join(root, "first"), "utf8"));
    expect(port).toBeGreaterThan(0);
    expect(port).not.toBe(8880);
    const other = Bun.spawn(["python3", "-B", "-c", fakeRuntime, entry, join(root, "other"), String(port)], {
      env: {...process.env, HOME: root}, stdout: "pipe", stderr: "pipe",
    });
    try {
      expect(await other.exited).toBe(1);
      expect(existsSync(join(root, "other.created"))).toBe(false);
      const body = await (await fetch(`http://127.0.0.1:${port}/health`)).json();
      expect(body).toMatchObject({status: "ok", pid: first.pid, model_loaded: false});
    } finally { if (other.exitCode === null) other.kill(); await other.exited; }
  } finally {
    first.kill(); await first.exited;
    rmSync(root, {recursive: true, force: true});
  }
}, 15000);
