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
  function hasEnv(node: ts.Expression | undefined, seen = new Set<string>()): boolean {
    if (!node) return false;
    if (ts.isIdentifier(node) && !seen.has(node.text)) {
      seen.add(node.text);
      return hasEnv(values.get(node.text), seen);
    }
    return ts.isObjectLiteralExpression(node) && node.properties.some(property => {
      if (ts.isSpreadAssignment(property)) return hasEnv(property.expression, new Set(seen));
      if (!property.name || property.name.getText(ast).replace(/["']/g, "") !== "env") return false;
      return ts.isShorthandPropertyAssignment(property) ||
        (ts.isPropertyAssignment(property) && !["undefined", "null"].includes(property.initializer.getText(ast)));
    });
  }
  const missing: string[] = [];
  function visit(node: ts.Node): void {
    let options: ts.Expression | undefined;
    let spawn = false;
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      const name = ts.isIdentifier(callee) ? callee.text : ts.isPropertyAccessExpression(callee) ? callee.name.text : "";
      spawn = functions.has(name) || (ts.isPropertyAccessExpression(callee) && APIs.has(name) &&
        namespaces.has(callee.expression.getText(ast)));
      if (spawn) {
        const bun = bunFunctions.has(name) || (ts.isPropertyAccessExpression(callee) && callee.expression.getText(ast) === "Bun");
        options = !bun && hasEnv(node.arguments[1])
          ? node.arguments[1] : bun && node.arguments[0] && ts.isObjectLiteralExpression(node.arguments[0])
          ? node.arguments[0] : node.arguments[bun ? 1 : (functions.get(name) ?? name).startsWith("exec") && !(functions.get(name) ?? name).startsWith("execFile") ? 1 : 2];
      }
    }
    if (ts.isTaggedTemplateExpression(node) && node.tag.getText(ast) === "Bun.$") {
      const access = node.parent;
      const call = access?.parent;
      spawn = !(access && ts.isPropertyAccessExpression(access) && access.name.text === "env" &&
        call && ts.isCallExpression(call) && call.arguments.length > 0);
    }
    if (spawn && !hasEnv(options)) {
      const line = ast.getLineAndCharacterOfPosition(node.getStart(ast)).line;
      // An exception belongs immediately above the call and must explain why.
      const preceding = source.split("\n")[line - 1] ?? "";
      if (!/\/\/ spawn-env-allow: \S.{15,}/.test(preceding)) missing.push(`${file}:${line + 1}: ${node.getText(ast).split("\n")[0]}`);
    }
    ts.forEachChild(node, visit);
  }
  visit(ast);
  return missing;
}
