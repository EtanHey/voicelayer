import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { dirname, join, relative, isAbsolute, sep } from "path";
import ts from "typescript";
import { privateSpecimenRoot } from "./setup/private-specimens";

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

  for (const file of ["stt-outro-gate.test.ts", "stt-chunk-segments.test.ts"]) {
    test(`${file} never probes the private corpus by default, even if every file exists`, () => {
      const probes: string[] = [];
      const messages: string[] = [];
      const noop = Object.assign(() => {}, { skip: () => {}, each: () => () => {} });
      register(file, {
        join, homedir: () => "/sandbox/private-home", TEST_TMP: "/sandbox/test-tmp",
        process: { env: { HOME: "/sandbox/private-home" } },
        privateSpecimenRoot: () => null,
        existsSync: (path: string) => { probes.push(path); return true; },
        readFileSync: () => { throw new Error("unexpected specimen read"); },
        describe: (_name: string, body: () => void) => body(), test: noop,
        afterEach: () => {}, Bun: { spawnSync: () => ({ exitCode: 1 }) },
        console: { error: (...args: unknown[]) => messages.push(args.join(" ")) },
      });
      expect(probes).toEqual([]);
      expect(messages.some(message => message.includes("VOICELAYER_TEST_REAL_ARCHIVE"))).toBe(true);
    });

    for (const explicit of [false, true]) {
      test(`${file} probes only the explicitly selected private source (${explicit ? "directory" : "archive opt-in"})`, () => {
        const env = {
          HOME: "/sandbox/private-home", VOICELAYER_TEST_REAL_ARCHIVE: "1",
          ...(explicit ? { VOICELAYER_TEST_SPECIMEN_DIR: "/sandbox/private-corpus" } : {}),
        };
        const probes: string[] = [];
        const active: string[] = [];
        let suite = "";
        const runnable = Object.assign((name: string) => active.push(`${suite}: ${name}`), {
          skip: () => {}, each: () => () => {},
        });
        register(file, {
          join, homedir: () => env.HOME, TEST_TMP: "/sandbox/test-tmp", process: { env },
          privateSpecimenRoot: () => privateSpecimenRoot(env),
          existsSync: (path: string) => { probes.push(path); return true; },
          readFileSync: () => { throw new Error("registration must never read a recording"); },
          describe: (name: string, body: () => void) => { suite = name; body(); }, test: runnable,
          afterEach: () => {}, Bun: { spawnSync: () => ({ exitCode: 1 }) }, console: { error() {} },
        });
        expect(probes.length).toBeGreaterThan(0);
        for (const path of probes) {
          expect(path).toStartWith(explicit ? "/sandbox/private-corpus/" : `${env.HOME}/`);
        }
        expect(active.some(name => /specimen|archived long-recording/.test(name))).toBe(true);
      });
    }
  }

  test("private specimen selection requires the exact opt-in or a nonempty explicit directory", () => {
    for (const flag of [undefined, "", "0", "true"]) {
      expect(privateSpecimenRoot({ HOME: "/sandbox/home", VOICELAYER_TEST_REAL_ARCHIVE: flag })).toBeNull();
    }
    expect(privateSpecimenRoot({ VOICELAYER_TEST_SPECIMEN_DIR: " " })).toBeNull();
    expect(privateSpecimenRoot({ HOME: "/sandbox/home", VOICELAYER_TEST_REAL_ARCHIVE: "1" }))
      .toBe("/sandbox/home/.local/share/voicelayer/recordings");
    expect(privateSpecimenRoot({ VOICELAYER_TEST_SPECIMEN_DIR: "/sandbox/explicit", VOICELAYER_TEST_REAL_ARCHIVE: "0" }))
      .toBe("/sandbox/explicit");
  });
});
