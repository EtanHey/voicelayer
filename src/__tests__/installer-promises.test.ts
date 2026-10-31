import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import ts from "typescript";

test("installer entry points never float validation/setup promises", () => {
  const failures: string[] = [];
  for (const file of ["src/update-gate-installer.ts", "src/cli/setup.ts"]) {
    const source = ts.createSourceFile(file, readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true);
    function visit(node: ts.Node) {
      if (ts.isCallExpression(node)) {
        const name = ts.isIdentifier(node.expression) ? node.expression.text :
          ts.isPropertyAccessExpression(node.expression) ? node.expression.name.text : "";
        if (["validateInstallerOperation", "runGatedInstall", "runSetup"].includes(name) && !ts.isAwaitExpression(node.parent)) {
          failures.push(`${file}:${source.getLineAndCharacterOfPosition(node.pos).line + 1}: ${name}`);
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(source);
  }
  expect(failures).toEqual([]);
  expect(readFileSync("scripts/lib/update-gate.sh", "utf8")).toMatch(/--validate\s*\|\|\s*return 1/);
});
