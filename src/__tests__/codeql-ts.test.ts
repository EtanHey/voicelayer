import { describe, expect, it, spyOn } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import { TEST_TMP } from "./setup/test-tmp";
import { normalizePathTokens } from "../stt-cleanup";
import { sanitizeTtsText, stripMarkupForSpeech } from "../sanitize";
import { buildSTTQualityMiningReport, formatSTTQualityMiningMarkdown } from "../stt-quality-mining";
import { createVoiceReviewApp, humanizeSpokenText } from "../voicereview-web/server";

// Frozen pre-fix oracle: exercised only on short synthetic strings (<= 28 chars).
// Never use this backtracking pattern on caller data or the 50k regression.
function legacyPathTokens(text: string): string {
  if (text.length > 28) throw new Error("legacy oracle only accepts bounded synthetic inputs");
  let result = text.replace(
    /\b(in|at|under|inside)\s+-\s*,\s+is it\s+(?=~\s*\/)/giu,
    (_match, preposition: string) => `${preposition} `,
  );
  result = result.replace(/~\s*\/[^,;!?]*/gu, (match) =>
    match.replace(/\s*\/\s*/g, "/").replace(/\s*-\s*/g, "-").toLowerCase(),
  );
  return result.replace(
    /(?<!\S)(?=[A-Za-z0-9._~-]*\s*\/)[A-Za-z0-9._~-]+(?:\s*[/-]\s*[A-Za-z0-9._~-]+)+(?!\S)/gu,
    (match) => {
      if (/^\/[A-Za-z0-9-]+$/u.test(match.trim())) return match;
      if (/^[A-Za-z]+\s+\/\s*[A-Za-z0-9-]+$/u.test(match.trim())) return match;
      return match.replace(/\s*\/\s*/g, "/").replace(/\s*-\s*/g, "-").toLowerCase();
    },
  );
}

function seededRandom(seed: number): () => number {
  return () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed;
  };
}

describe("CodeQL TypeScript regressions", () => {
  it("r2 preserves comparisons and incomplete markup in shared and server speech helpers", () => {
    for (const text of ["latency > 2s", "a < b", "x > 5 and y < 3", "שלום > 2 < עוד"]) {
      expect(stripMarkupForSpeech(text)).toBe(text);
      expect(sanitizeTtsText(text)).toBe(text);
      expect(humanizeSpokenText(text)).toBe(text);
    }
    expect(stripMarkupForSpeech("<scr<script>ipt>alert(1)</script>")).toBe("alert(1)");
    expect(stripMarkupForSpeech("before <outer <inner> unfinished")).toBe("before <outer  unfinished");
  });

  it("r2 preserves comparisons in the generated browser speech helper", async () => {
    const root = await mkdtemp(join(TEST_TMP, "codeql-browser-"));
    try {
      const app = createVoiceReviewApp({ config: { batchPath: join(root, "missing.json"), enableClonedTts: false } });
      const html = await (await app.fetch(new Request("http://localhost/"))).text();
      const source = html.match(/const stripMarkupForSpeech = ([^]*?);\s*function humanizeSpokenText/u)?.[1];
      expect(source).toBeDefined();
      const strip: (text: string) => string = runInNewContext(`(${source})`);
      for (const text of ["latency > 2s", "a < b", "x > 5 and y < 3"]) expect(strip(text)).toBe(text);
      expect(strip("<scr<script>ipt>alert(1)</script>")).toBe("alert(1)");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("r2 seeded markup output never leaves an opening bracket followed by a closing bracket", () => {
    const random = seededRandom(0x53504545);
    const alphabet = Array.from("abc019 <>/\tשלוםé");
    for (let sample = 0; sample < 20000; sample++) {
      let text = "";
      const size = random() % 40;
      for (let i = 0; i < size; i++) text += alphabet[random() % alphabet.length];
      expect(stripMarkupForSpeech(text)).not.toMatch(/<[^]*>/u);
    }
  });

  it("r2 matches the frozen legacy path oracle on 20000 fixed-seed short strings", () => {
    const random = seededRandom(0x004c514c);
    const alphabet = Array.from("abcdefghijklmnopqrstuvwxyz0123456789._~/- \téא中");
    expect(() => legacyPathTokens("x".repeat(29))).toThrow("bounded synthetic inputs");
    const started = performance.now();
    for (let sample = 0; sample < 20000; sample++) {
      let text = sample % 2 === 0 ? "aA/" : "";
      const size = random() % 24;
      for (let i = 0; i < size; i++) text += alphabet[random() % alphabet.length];
      expect(normalizePathTokens(text)).toBe(legacyPathTokens(text));
    }
    expect(performance.now() - started).toBeLessThan(2000);
  });

  it("#5 path normalization finishes a 50k-character hyphen near-miss within 100ms without losing text", async () => {
    const script = `
      import { normalizePathTokens } from './src/stt-cleanup.ts';
      const input = 'retain Path/' + '--'.repeat(25000) + '!';
      const start = performance.now();
      const output = normalizePathTokens(input);
      console.log(JSON.stringify({ elapsed: performance.now() - start, intact: output === 'retain Path/' + '--'.repeat(25000) + '!' }));
    `;
    const child = Bun.spawn([process.execPath, "--eval", script], { stdout: "pipe", stderr: "pipe" });
    // A subprocess deadline makes the RED exponential case safe for the test runner.
    const timer = setTimeout(() => child.kill(), 2000);
    try {
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      expect(stderr).toBe("");
      expect(code).toBe(0);
      const result = JSON.parse(stdout);
      expect(result.intact).toBe(true);
      expect(result.elapsed).toBeLessThan(100);
    } finally {
      clearTimeout(timer);
      child.kill();
      await child.exited;
    }
  }, 5000);

  it("#5 preserves greedy path boundaries and conversational slashes", () => {
    for (const [input, expected] of [
      ["Repo/FILE - Tail", "repo/file-tail"],
      ["Repo/FILE- Tail", "repo/file- Tail"],
      ["Repo / FILE", "Repo / FILE"],
      ["Repo/FILE! other/X", "Repo/FILE! other/x"],
      ["Aa/~-\nA", "aa/~-\nA"],
      ["keep and/or wording", "keep and/or wording"],
      ["Repo///Tail", "Repo///Tail"],
    ]) expect(normalizePathTokens(input)).toBe(expected);
  });

  it("#8 strips tags reintroduced by nested removal and handles repeated tags", () => {
    expect(sanitizeTtsText("<scrip<script>t>hello</scrip</script>t>")).toBe("hello");
    expect(sanitizeTtsText("<speak>one</speak> <speak>two</speak>")).toBe("one two");
    expect(sanitizeTtsText("<script incomplete")).toBe("<script incomplete");
    expect(sanitizeTtsText("plain text < unfinished words")).toBe("plain text < unfinished words");
    expect(sanitizeTtsText("שלום <b>one</b> fu… two")).toBe("שלום one fu… two");
  });

  it("#9 strips reintroduced tags from spoken narration", () => {
    expect(humanizeSpokenText("<scrip<script>t>hello</scrip</script>t>")).toBe("hello");
    expect(humanizeSpokenText("<b>one</b> <b>two</b>")).toBe("one two");
  });

  it("#7 encodes stored profile names in HTML attributes and inline script data", async () => {
    const root = await mkdtemp(join(TEST_TMP, "codeql-web-"));
    try {
      const payload = '</script><script>alert("synthetic")</script><img src=x onerror="synthetic">';
      const app = createVoiceReviewApp({
        config: { batchPath: join(root, "missing.json"), enableClonedTts: true },
        ttsEngines: { listClonedProfiles: () => [payload, 'quote" onmouseover="synthetic'], hasClonedProfile: () => false, synthesizeCloned: async () => null },
      });
      const response = await app.fetch(new Request("http://localhost/"));
      const html = await response.text();
      expect(response.headers.get("content-type")).toContain("text/html");
      expect(html).not.toContain(payload);
      expect(html).toContain('&lt;/script&gt;&lt;script&gt;alert(&quot;synthetic&quot;)');
      const data = html.match(/const CLONED_TTS_VOICES = new Set\(([^\n]+)\);/)?.[1];
      expect(data).toBeDefined();
      expect(data).not.toContain("<");
      expect(JSON.parse(data!)).toEqual([payload, 'quote" onmouseover="synthetic']);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("#7 escapes names read from stored clone directories at both option boundaries", async () => {
    const root = await mkdtemp(join(TEST_TMP, "codeql-stored-clone-"));
    const payload = 'fixture&&""<<img src=x onerror="synthetic">>';
    const escaped = 'fixture&amp;&amp;&quot;&quot;&lt;&lt;img src=x onerror=&quot;synthetic&quot;&gt;&gt;';
    try {
      const profileDir = join(root, ".voicelayer", "voices", payload);
      await mkdir(profileDir, { recursive: true });
      await writeFile(join(profileDir, "profile.yaml"), "name: synthetic-clone\n");
      // Separate process ensures qwen3 captures only this synthetic HOME at import.
      const script = `
        const { listClonedVoiceProfiles } = await import('./src/tts/qwen3.ts');
        const { createVoiceReviewApp } = await import('./src/voicereview-web/server.ts');
        const names = listClonedVoiceProfiles();
        const app = createVoiceReviewApp({
          config: { batchPath: ${JSON.stringify(join(root, "missing.json"))}, enableClonedTts: true },
          ttsEngines: { listClonedProfiles: listClonedVoiceProfiles, hasClonedProfile: () => false, synthesizeCloned: async () => null },
        });
        const html = await (await app.fetch(new Request('http://localhost/'))).text();
        console.log(JSON.stringify({ names, html }));
      `;
      const child = Bun.spawn([process.execPath, "--eval", script], {
        env: { ...process.env, HOME: root }, stdout: "pipe", stderr: "pipe",
      });
      const [code, stdout, stderr] = await Promise.all([
        child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
      ]);
      expect(stderr).toBe("");
      expect(code).toBe(0);
      const { names, html } = JSON.parse(stdout);
      expect(names).toEqual([payload]);
      expect(html).toContain(`value="${escaped}">${escaped}</option>`);
      expect(html).not.toContain(payload);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  for (const [alert, target] of [[10, "recurring"], [11, "pattern"], [12, "detail"]] as const) {
    it(`#${alert} keeps backslashes, pipes, HTML and line breaks inside one Markdown table cell`, () => {
      const report = buildSTTQualityMiningReport({ recordings: [], freshDecodes: [], cleanupPairs: [], polishPairs: [], correctionPairs: [] });
      const payload = "a\\|b\\\\|c`<img src=x>\nextra";
      const escaped = "a&#92;&#124;b&#92;&#92;&#124;c&#96;&lt;img src=x&gt; extra";
      if (target === "recurring") {
        report.recurringPatterns = [{ category: "filler_disfluency_handling", pattern: payload, count: 1, severity: "low" }];
      } else {
        report.passes[0].findings = [{ category: "filler_disfluency_handling", pass: "synthetic", candidateId: "fixture", source: "archived", pattern: target === "pattern" ? payload : "plain", detail: target === "detail" ? payload : "plain", severity: "low" }];
      }
      const markdown = formatSTTQualityMiningMarkdown(report);
      expect(markdown).toContain(escaped);
      expect(markdown).not.toContain("<img");
      expect(markdown).not.toContain("\nextra");
    });
  }

  it("#13 returns a generic 500 body while logging diagnostics on the server", async () => {
    const root = await mkdtemp(join(TEST_TMP, "codeql-error-"));
    const diagnostic = new Error("synthetic /private/fixture.ts:123\n at internalFunction");
    const log = spyOn(console, "error").mockImplementation(() => {});
    try {
      const app = createVoiceReviewApp({ config: { decisionsPath: join(root, "decisions.json") }, runCommand: async () => { throw diagnostic; } });
      const response = await app.fetch(new Request("http://localhost/api/stats"));
      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "Internal server error" });
      expect(log).toHaveBeenCalledWith("[voicereview] request failed", diagnostic);
    } finally {
      log.mockRestore();
      await rm(root, { recursive: true, force: true });
    }
  });
});
