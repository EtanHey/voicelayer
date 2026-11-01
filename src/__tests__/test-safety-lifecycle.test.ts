import { describe, expect, test, spyOn } from "bun:test";
import { readFileSync } from "fs";
import { dirname, join, relative, isAbsolute, sep } from "path";
import ts from "typescript";
import { privateCorpusEnabled, privateCorpusPaths } from "./setup/private-specimens";

// Execute the actual suite registration/hooks with a virtual filesystem. Test
// bodies, native imports, private recordings and resident PID files never run.
function register(file: string, deps: Record<string, unknown>, until?: string) {
  let source = readFileSync(join(import.meta.dir, file), "utf8");
  if (until) source = source.slice(0, source.indexOf(until));
  source = source.replaceAll("import.meta.dir", JSON.stringify(import.meta.dir));
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const body = ts.factory.updateSourceFile(ast, ast.statements.filter(n => !ts.isImportDeclaration(n)));
  const js = ts.transpileModule(ts.createPrinter().printFile(body), {
    compilerOptions: { module: ts.ModuleKind.None, target: ts.ScriptTarget.ESNext },
  }).outputText;
  new Function(...Object.keys(deps), js)(...Object.values(deps));
}

describe("TEST3 review: setup and private specimen safety", () => {
  for (const unsafe of ["daemon", "mcp"]) {
    for (const phase of ["beforeEach", "afterEach"]) {
      test(`${phase} validates both PID paths before any cleanup (${unsafe} outside run)`, () => {
        const root = "/sandbox/.test-tmp/1234-abcd";
        const daemon = join(unsafe === "daemon" ? "/sandbox/resident" : root, "voicelayer-daemon.pid");
        const mcp = unsafe === "mcp" ? "/sandbox/resident-mcp.pid" : join(root, "mcp.pid");
        const files = new Map([[daemon, "daemon sentinel"], [mcp, "mcp sentinel"]]);
        const io: string[] = [];
        const hooks: Record<string, Array<() => void>> = { beforeEach: [], afterEach: [] };
        register("daemon.test.ts", {
          join, getTmpRoot: () => dirname(daemon), getMcpPidFilePath: () => mcp,
          assertTestPidPath: (path: string) => {
            const tail = relative(root, path);
            if (!tail || tail === ".." || tail.startsWith(`..${sep}`) || isAbsolute(tail)) {
              throw new Error("test PID lock refused outside the isolated run");
            }
          },
          describe: (_name: string, body: () => void) => body(), it: () => {},
          beforeEach: (fn: () => void) => hooks.beforeEach.push(fn),
          afterEach: (fn: () => void) => hooks.afterEach.push(fn),
          existsSync: (path: string) => { io.push(`exists:${path}`); return files.has(path); },
          unlinkSync: (path: string) => { io.push(`unlink:${path}`); files.delete(path); },
          releaseProcessLock: (path: string) => io.push(`release:${path}`),
        }, 'describe("daemon has no MCP imports"');
        expect(hooks[phase]).toHaveLength(1);
        expect(hooks[phase][0]).toThrow(/test PID lock/);
        expect(io).toEqual([]);
        expect([...files.values()]).toEqual(["daemon sentinel", "mcp sentinel"]);
      });
    }
  }

  const suites = ["stt-outro-gate.test.ts", "stt-chunk-segments.test.ts",
    "rules-engine-number-audio.test.ts", "rules-engine-prose-guard.test.ts"];
  for (const file of suites) {
    for (const override of [false, true]) {
      test(`${file} never probes without opt-in (overrides=${override}, all files exist)`, () => {
        const probes: string[] = [];
        const messages: string[] = [];
        const env = {
          ...(override ? { VOICELAYER_TEST_SPECIMEN_DIR: "/sandbox/explicit",
            VOICELAYER_NUMBERS_CORPUS_PATH: "/sandbox/manifest.json",
            QA_VOICE_STT_POLISH_LOG_PATH: "/sandbox/shadow.jsonl" } : {}),
          get HOME(): string { throw new Error("HOME resolved before opt-in"); },
        };
        const noop = Object.assign(() => {}, { skip: () => {}, each: () => () => {} });
        const describeSuite = Object.assign((_name: string, body: () => void) => body(), { skipIf: () => () => {} });
        const report = spyOn(console, "error").mockImplementation((...args) => messages.push(args.join(" ")));
        try {
          register(file, {
            join, TEST_TMP: "/sandbox/test-tmp", process: { env },
            homedir: () => { throw new Error("home resolved before opt-in"); },
            privateCorpusPaths: () => privateCorpusPaths(file, env),
            existsSync: (path: string) => { probes.push(path); return true; },
            readFileSync: () => { throw new Error("unexpected specimen read"); },
            describe: describeSuite, test: noop, it: noop,
            afterEach: () => {}, Bun: { spawnSync: () => ({ exitCode: 1 }) },
            console: { error: (...args: unknown[]) => messages.push(args.join(" ")) },
          });
        } finally { report.mockRestore(); }
        expect(probes).toEqual([]);
        expect(messages.some(message => message.includes("VOICELAYER_TEST_REAL_ARCHIVE"))).toBe(true);
      });
    }

    for (const explicit of [false, true]) {
      test(`${file} registers private tests only after opt-in (overrides=${explicit})`, () => {
        const env = {
          HOME: "/sandbox/private-home", VOICELAYER_TEST_REAL_ARCHIVE: "1",
          // This VM registers test bodies without executing a tool or model.
          ...(file === "rules-engine-number-audio.test.ts" ? { QA_VOICE_GOLDEN_LIVE: "1" } : {}),
          ...(explicit ? { VOICELAYER_TEST_SPECIMEN_DIR: "/sandbox/private-corpus",
            VOICELAYER_NUMBERS_CORPUS_PATH: "/sandbox/manifest.json",
            QA_VOICE_STT_POLISH_LOG_PATH: "/sandbox/shadow.jsonl" } : {}),
        };
        const probes: string[] = [];
        const active: string[] = [];
        let suite = "";
        const runnable = Object.assign((name: string) => active.push(`${suite}: ${name}`), {
          skip: () => {}, each: () => () => {},
        });
        const describeSuite = Object.assign((name: string, body: () => void) => { suite = name; body(); }, {
          skipIf: (skip: boolean) => (name: string, body: () => void) => { if (!skip) { suite = name; body(); } },
        });
        register(file, {
          join, TEST_TMP: "/sandbox/test-tmp", process: { env },
          privateCorpusPaths: () => privateCorpusPaths(file, env),
          existsSync: (path: string) => { probes.push(path); return true; },
          readFileSync: () => { throw new Error("registration must never read private data"); },
          describe: describeSuite, test: runnable, it: runnable,
          afterEach: () => {}, Bun: { spawnSync: () => ({ exitCode: 1 }) }, console: { error() {} },
        });
        expect(probes.length).toBeGreaterThan(0);
        const paths = privateCorpusPaths(file, env)!;
        for (const path of probes) {
          expect([paths.recordings + "/", paths.correctionTsv, paths.numbersManifest,
            paths.prosePairs, paths.proseGold, paths.polishShadow].some(root => path.startsWith(root))).toBe(true);
        }
        expect(active.some(name => /specimen|archived long-recording|timestamped audio|never drops a word/.test(name))).toBe(true);
      });
    }
  }

  test("only the exact archive flag enables any private path; overrides cannot authorize it", () => {
    const report = spyOn(console, "error").mockImplementation(() => {});
    try {
      for (const flag of [undefined, "", "0", "true", " 1", "1 ", "yes"]) {
        const env = { VOICELAYER_TEST_REAL_ARCHIVE: flag, VOICELAYER_TEST_SPECIMEN_DIR: "/sandbox/explicit",
          VOICELAYER_NUMBERS_CORPUS_PATH: "/sandbox/manifest.json",
          get HOME(): string { throw new Error("HOME resolved before opt-in"); } };
        expect(privateCorpusEnabled(env)).toBe(false);
        expect(privateCorpusPaths("unit", env)).toBeNull();
      }
    } finally { report.mockRestore(); }
    expect(privateCorpusEnabled({ VOICELAYER_TEST_REAL_ARCHIVE: "1" })).toBe(true);
    const env = { HOME: "/sandbox/home", VOICELAYER_TEST_REAL_ARCHIVE: "1" };
    expect(privateCorpusPaths("unit", env)?.recordings).toBe("/sandbox/home/.local/share/voicelayer/recordings");
    expect(privateCorpusPaths("unit", { ...env, VOICELAYER_TEST_SPECIMEN_DIR: "/sandbox/explicit" })?.recordings)
      .toBe("/sandbox/explicit");
    expect(privateCorpusPaths("unit", { ...env, QA_VOICE_STT_POLISH_LOG_PATH: "/sandbox/shadow.jsonl" })?.polishShadow)
      .toBe("/sandbox/shadow.jsonl");
  });
});
