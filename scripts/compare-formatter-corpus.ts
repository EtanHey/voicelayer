/** Compare old/new production formatters on executed fixtures and bounded probes.
 * Usage: bun scripts/compare-formatter-corpus.ts [BASE] PROBES.json OUTDIR [REVIEW.json]
 * REVIEW maps SHA256 difference ids to a reviewed explanation; unknowns fail.
 */
import { appendFileSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createHash } from "node:crypto";
import ts from "typescript";
import layoutCorpus from "../src/__tests__/fixtures/layout-intent-corpus.json";
const args = process.argv.slice(2);
const base = args[0]?.endsWith(".json") ? "origin/test/2.4-candidate-1110c" : args.shift() ?? "origin/test/2.4-candidate-1110c";
const [probesFile, output, reviewFile] = args;
if (!probesFile || !output) throw new Error("[BASE] PROBES.json OUTDIR [REVIEW.json] required");
const root = process.cwd(), out = resolve(output);
mkdirSync(out, { recursive: true });
const run = (args: string[]) => {
  const r = Bun.spawnSync(args, { env: process.env, stdout: "pipe", stderr: "pipe" });
  if (r.exitCode) throw new Error(new TextDecoder().decode(r.stderr));
  return r.stdout;
};
const baseSha = new TextDecoder().decode(run(["git", "rev-parse", base])).trim();
if (baseSha !== layoutCorpus.oldCommit) throw new Error("OLD corpus source differs from selected base");
const scratch = join(root, ".build.noindex/t2-equivalence", baseSha);
const oldRoot = join(scratch, "old"), newRoot = join(scratch, "new");
mkdirSync(oldRoot, { recursive: true }); mkdirSync(newRoot, { recursive: true });
const archive = run(["git", "archive", baseSha, "src"]);
const unpack = Bun.spawnSync(["tar", "-xf", "-", "-C", oldRoot], { env: process.env, stdin: archive, stderr: "pipe" });
if (unpack.exitCode) throw new Error("Cannot extract old source");
cpSync(join(oldRoot, "src"), join(newRoot, "src"), { recursive: true });
for (const name of new TextDecoder().decode(run(["git", "ls-files", "src"])).trim().split("\n")) {
  if (existsSync(name)) cpSync(name, join(newRoot, name));
}
for (const dir of [oldRoot, newRoot]) {
  appendFileSync(join(dir, "src/stt-polish.ts"), "\nexport { validatePolishCandidate as compareValidate };\n");
}
for (const name of ["stt-punctuation.ts", "stt-paragraphs.ts", "stt-coherent-paragraphs.ts"]) {
  if (!readFileSync(join(oldRoot, "src", name)).equals(readFileSync(join(newRoot, "src", name))))
    throw new Error(`Unrelated stage changed: ${name}`);
}
const capture = join(out, "calls.jsonl"); writeFileSync(capture, "");
const files = readdirSync("src/__tests__").filter(name => /^(?:rules-engine|stt-(?:polish|punctuation|paragraph|coherent-paragraph|formatting|cleanup|corrector)|dictation-numbers|dictionary-number-aliases|format-response|formatter-fidelity).*\.test\.ts$/u.test(name))
  .map(name => "src/__tests__/" + name).sort();
const fixtureRun = Bun.spawnSync([process.execPath, "test", "--preload", join(root, "scripts/formatter-corpus-preload.ts"), ...files], {
  env: { ...process.env, T2_OLD_SRC: join(oldRoot, "src"), T2_NEW_SRC: join(newRoot, "src"), T2_CAPTURE: capture,
    VOICELAYER_TEST_REAL_ARCHIVE: "0", QA_VOICE_GOLDEN_LIVE: "0", VOICELAYER_TEST_REAL_MIC: "0" },
  stdout: "pipe", stderr: "pipe",
});
writeFileSync(join(out, "fixtures.log"), Buffer.concat([fixtureRun.stdout, fixtureRun.stderr]));
const old = await import(join(oldRoot, "src/rules-engine.ts"));
const current = await import(join(newRoot, "src/rules-engine.ts"));
const oldFloor = await import(join(oldRoot, "src/stt-punctuation.ts"));
const newFloor = await import(join(newRoot, "src/stt-punctuation.ts"));
const probes: string[] = JSON.parse(readFileSync(resolve(probesFile), "utf8"));
// Literal superset also covers static inputs in skipped tests without opening
// gated private corpora. Executed capture above covers generated fixture inputs.
const literals = new Set<string>();
for (const file of files) {
  const visit = (node: ts.Node): void => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) literals.add(node.text);
    ts.forEachChild(node, visit);
  };
  visit(ts.createSourceFile(file, readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true));
}
const templates = [
  "this one works", "that one failed", "one or two", "between one and five",
  "one, two, three", "at one o'clock", "one thing", "version one point two",
  "add this to new line dot env", "Run new line dot slash build dot sh",
  "foo new line close paren new line bar", "first new line comma new line second",
  "there is an extra new line here?", "the sample has a trailing new line?",
  "remove the unwanted new paragraph now", "add a new line", "one of them",
  "no one knows", "each one matters", "keep the one I chose",
];
const synthetic = Array.from({ length: 200 }, (_, i) => `${templates[i % templates.length]} ${i % 2 ? "new line" : "comma"} sample ${i}`);
const intentCases = [...layoutCorpus.commands, ...layoutCorpus.legacyCommands, ...layoutCorpus.nouns, ...layoutCorpus.percent];
for (const input of [...probes, ...synthetic, ...literals, ...intentCases.map(row => row.input)]) {
  for (const [stage, before, after] of [
    ["applyRules", old.applyRules(input), current.applyRules(input)],
    ["restoreSentencePunctuation", oldFloor.restoreSentencePunctuation(input), newFloor.restoreSentencePunctuation(input)],
  ]) appendFileSync(capture, JSON.stringify({ stage, equal: before === after, ...(before === after ? {} : { args: [input], old: { value: before }, current: { value: after } }) }) + "\n");
}
const commandRegressions = layoutCorpus.commands.filter(row =>
  !row.old.includes("\n") || old.applyRules(row.input) !== row.old || current.applyRules(row.input) !== row.old);
const nounFailures = layoutCorpus.nouns.filter(row => current.applyRules(row.input) !== row.expected);
const calls = readFileSync(capture, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
interface Difference { id: string; stage: string; input: unknown[]; old: unknown; new: unknown }
const differences = new Map<string, Difference>();
for (const call of calls.filter(call => !call.equal)) {
  const id = createHash("sha256").update(JSON.stringify([call.stage, call.args, call.old, call.current])).digest("hex");
  differences.set(id, { id, stage: call.stage, input: call.args, old: call.old, new: call.current });
}
const reviews: Record<string, string> = reviewFile ? JSON.parse(readFileSync(resolve(reviewFile), "utf8")) : {};
const rows = [...differences.values()].map(row => ({ ...row, explanation: reviews[String(row.id)] ?? null }));
const stages = Object.fromEntries([...new Set(calls.map(call => call.stage))].map(stage =>
  [stage, calls.filter(call => call.stage === stage).length]));
if (!stages.applyRules || !stages["polish-validation"]) throw new Error("Fixture capture missed a changed stage");
const summary = { baseSha, fixtureFiles: files, fixtureExit: fixtureRun.exitCode, fixtureCalls: calls.length - 2 * (probes.length + 200 + literals.size + intentCases.length),
  stages, sourceSHA256: Object.fromEntries(["src/rules-engine.ts", "src/stt-polish.ts"].map(name =>
    [name, createHash("sha256").update(readFileSync(name)).digest("hex")])),
  probes: probes.length, synthetic: synthetic.length, fixtureLiterals: literals.size, totalCalls: calls.length, differences: rows.length,
  commandCases: layoutCorpus.commands.length, commandRegressions: commandRegressions.length, nounCases: layoutCorpus.nouns.length, nounFailures: nounFailures.length,
  unexplained: rows.filter(row => !row.explanation).length };
writeFileSync(join(out, "differences.json"), JSON.stringify(rows, null, 2) + "\n");
writeFileSync(join(out, "DIFFERENCES.md"), "# Every distinct old/new output difference\n\n" + rows.map((row, i) =>
  `## ${i + 1}. ${row.id}\n\n${row.explanation ?? "UNEXPLAINED"}\n\n\`\`\`json\n${JSON.stringify(row, null, 2)}\n\`\`\`\n`).join("\n"));
writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2) + "\n");
console.log(JSON.stringify(summary));
process.exitCode = fixtureRun.exitCode || (summary.unexplained || commandRegressions.length || nounFailures.length ? 1 : 0);
