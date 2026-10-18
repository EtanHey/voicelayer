import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import ts from "typescript";

const APIs = new Set(["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]);

/** Review guard for ordinary Bun/child_process calls, aliases and helper options. */
export function missingSpawnEnvs(source: string, file = "fixture.ts"): string[] {
  const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const functions = new Map<string, string>();
  const namespaces = new Set(["Bun"]);
  const bunFunctions = new Set<string>();
  const values = new Map<string, ts.Expression>();
  for (const statement of ast.statements) {
    if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier)) continue;
    const module = statement.moduleSpecifier.text;
    if (!["child_process", "node:child_process", "bun"].includes(module)) continue;
    const clause = statement.importClause;
    if (clause?.name) namespaces.add(clause.name.text);
    const bindings = clause?.namedBindings;
    if (bindings && ts.isNamespaceImport(bindings)) namespaces.add(bindings.name.text);
    if (bindings && ts.isNamedImports(bindings)) {
      for (const specifier of bindings.elements) {
        if (APIs.has((specifier.propertyName ?? specifier.name).text)) {
          functions.set(specifier.name.text, (specifier.propertyName ?? specifier.name).text);
          if (module === "bun") bunFunctions.add(specifier.name.text);
        }
      }
    }
  }
  function collect(node: ts.Node): void {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      values.set(node.name.text, node.initializer);
    }
    ts.forEachChild(node, collect);
  }
  collect(ast);
  // Captured originals in spy wrappers are child-process calls too.
  for (let pass = 0; pass < values.size + 1; pass++) {
    for (const [name, value] of values) {
      let target = value;
      if (ts.isCallExpression(target) && ts.isPropertyAccessExpression(target.expression) &&
          target.expression.name.text === "bind") target = target.expression.expression;
      if (ts.isPropertyAccessExpression(target) && APIs.has(target.name.text) &&
          namespaces.has(target.expression.getText(ast))) {
        functions.set(name, target.name.text);
        if (target.expression.getText(ast) === "Bun") bunFunctions.add(name);
      } else if (ts.isIdentifier(target) && functions.has(target.text)) {
        functions.set(name, functions.get(target.text)!);
        if (bunFunctions.has(target.text)) bunFunctions.add(name);
      }
    }
  }
  function isolatedEnv(node: ts.Expression | undefined, seen = new Set<string>()): boolean {
    if (!node) return false;
    if (node.getText(ast) === "process.env") return true;
    if (ts.isIdentifier(node) && !seen.has(node.text)) {
      seen.add(node.text);
      return isolatedEnv(values.get(node.text), seen);
    }
    return ts.isObjectLiteralExpression(node) && node.properties.some(property =>
      ts.isSpreadAssignment(property) && isolatedEnv(property.expression, new Set(seen)));
  }
  function envStatus(node: ts.Expression | undefined, seen = new Set<string>()): boolean | undefined {
    if (!node) return false;
    if (ts.isIdentifier(node) && !seen.has(node.text)) {
      seen.add(node.text);
      return envStatus(values.get(node.text), seen);
    }
    if (!ts.isObjectLiteralExpression(node)) return false;
    let status: boolean | undefined;
    for (const property of node.properties) {
      if (ts.isSpreadAssignment(property)) {
        const inherited = envStatus(property.expression, new Set(seen));
        if (inherited !== undefined) status = inherited;
      } else if (property.name?.getText(ast).replace(/["']/g, "") === "env") {
        status = isolatedEnv(ts.isShorthandPropertyAssignment(property) ? property.name :
          ts.isPropertyAssignment(property) ? property.initializer : undefined);
      }
    }
    return status;
  }
  function exempt(line: number): boolean {
    const reason = /^\s*\/\/ isolation-exempt: (.+)$/.exec(source.split("\n")[line - 1] ?? "")?.[1];
    const words = reason?.match(/[a-z][a-z-]+/gi) ?? [];
    // The tag makes exemptions reviewable; word diversity rejects filler. A human still reviews the reason.
    return !!reason && reason.length >= 40 && words.length >= 6 && new Set(words.map(word => word.toLowerCase())).size >= 5;
  }
  const missing: string[] = [];
  function visit(node: ts.Node): void {
    let options: ts.Expression | undefined;
    let spawn = false;
    let shellEnv = false;
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      const name = ts.isIdentifier(callee) ? callee.text : ts.isPropertyAccessExpression(callee) ? callee.name.text : "";
      spawn = functions.has(name) || (ts.isPropertyAccessExpression(callee) && APIs.has(name) &&
        namespaces.has(callee.expression.getText(ast)));
      if (spawn) {
        const bun = bunFunctions.has(name) || (ts.isPropertyAccessExpression(callee) && callee.expression.getText(ast) === "Bun");
        options = !bun && envStatus(node.arguments[1]) === true
          ? node.arguments[1] : bun && node.arguments[0] && ts.isObjectLiteralExpression(node.arguments[0])
          ? node.arguments[0] : node.arguments[bun ? 1 : (functions.get(name) ?? name).startsWith("exec") && !(functions.get(name) ?? name).startsWith("execFile") ? 1 : 2];
      }
    }
    if (ts.isTaggedTemplateExpression(node) && node.tag.getText(ast) === "Bun.$") {
      const access = node.parent;
      const call = access?.parent;
      spawn = true;
      shellEnv = !!(access && ts.isPropertyAccessExpression(access) && access.name.text === "env" &&
        call && ts.isCallExpression(call) && isolatedEnv(call.arguments[0]));
    }
    if (spawn && !shellEnv && envStatus(options) !== true) {
      const line = ast.getLineAndCharacterOfPosition(node.getStart(ast)).line;
      if (!exempt(line)) missing.push(`${file}:${line + 1}: ${node.getText(ast).split("\n")[0]}`);
    }
    ts.forEachChild(node, visit);
  }
  visit(ast);
  return missing;
}

/** Match the declared Bun test roots, plus helper sources in the two test trees. */
export function testSourceFiles(root: string): string[] {
  function walk(dir: string): string[] {
    if (!existsSync(dir)) return [];
    return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
      const path = join(dir, entry.name);
      return entry.isDirectory() ? walk(path) : /\.[cm]?[jt]sx?$/.test(path) ? [path] : [];
    });
  }
  const command = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).scripts.test;
  const [binary, action, ...roots] = command.trim().split(/\s+/) as string[];
  if (binary !== "bun" || action !== "test" || roots.length === 0 || roots.some(dir => !/^\.\/[\w/-]+$/.test(dir))) {
    throw new Error("Spawn guard requires explicit package.json Bun test roots");
  }
  return roots.flatMap(dir => walk(join(root, dir))).filter(file => {
    const name = relative(root, file);
    return name.startsWith("src/__tests__/") || name.startsWith("tests/") || /[._](?:test|spec)\.[cm]?[jt]sx?$/.test(name);
  });
}
