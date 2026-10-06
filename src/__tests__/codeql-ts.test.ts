import { describe, expect, it, spyOn } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { TEST_TMP } from "./setup/test-tmp";
import { normalizePathTokens } from "../stt-cleanup";
import { sanitizeTtsText } from "../sanitize";
import { buildSTTQualityMiningReport, formatSTTQualityMiningMarkdown } from "../stt-quality-mining";
import { createVoiceReviewApp, humanizeSpokenText } from "../voicereview-web/server";

describe("CodeQL TypeScript regressions", () => {
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
    expect(sanitizeTtsText("<script incomplete")).toBe("script incomplete");
    expect(sanitizeTtsText("plain text < unfinished words")).toBe("plain text unfinished words");
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
