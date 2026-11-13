// T3CODE_DIR=/path/to/t3code bun tests/fixtures/typed-delivery/build-fixture.ts <outdir>
// Bundles editors.ts against a READ-ONLY T3 Code checkout: its apps/web sources and its installed
// node_modules. Builds nothing inside that checkout. T3CODE_DIR is required (no default): point it at
// your own t3code clone with dependencies installed.
import { dirname, join } from "node:path";
const outdir = Bun.argv[2] ?? ".build.noindex/typed-delivery-fixture";
const here = dirname(Bun.fileURLToPath(import.meta.url));
const T3 = process.env.T3CODE_DIR;
if (!T3) {
  console.error("T3CODE_DIR is not set: point it at a read-only t3code checkout with node_modules installed");
  process.exit(2);
}
const roots = [`${T3}/apps/web/node_modules`, `${T3}/node_modules/.pnpm/node_modules`, `${T3}/node_modules`];
const result = await Bun.build({
  entrypoints: [join(here, "editors.ts")],
  target: "browser",
  plugins: [{
    name: "t3-checkout",
    setup(build) {
      build.onResolve({ filter: /^t3web\// }, (args) => ({ path: `${T3}/apps/web/src/${args.path.slice(6)}.ts` }));
      build.onResolve({ filter: /^@?[a-z]/ }, (args) => {
        for (const root of roots) {
          try { return { path: Bun.resolveSync(args.path, `${root}/`) }; } catch {}
        }
        return undefined;
      });
    },
  }],
});
if (!result.success) { for (const log of result.logs) console.error(log); process.exit(1); }
await Bun.write(join(outdir, "editors.js"), await result.outputs[0].text());
await Bun.write(join(outdir, "index.html"), Bun.file(join(here, "index.html")));
const head = Bun.spawnSync(["git", "-C", T3, "rev-parse", "HEAD"], { env: process.env }).stdout.toString().trim();
await Bun.write(join(outdir, "T3CODE_HEAD"), head + "\n");
console.log(`fixture -> ${outdir} (t3code ${head})`);
