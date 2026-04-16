import { describe, expect, test } from "bun:test";

const html = await Bun.file(
  new URL("../landing/index.html", import.meta.url),
).text();

describe("landing page polish audit", () => {
  test("reflects the content, accessibility, responsive, and motion fixes", () => {
    expect(html).toContain('class="skip-link"');
    expect(html.indexOf('class="skip-link"')).toBeLessThan(
      html.indexOf('<nav id="nav">'),
    );
    expect(html).toContain('<main id="main-content">');

    expect(html).toContain('<span class="stat-value">11</span>');
    expect(html).toContain('<span class="stat-label">MCP tools</span>');
    expect(html).toContain('<span class="stat-value">546</span>');
    expect(html).toContain('<span class="stat-label">tests passing</span>');
    expect(html).toMatch(
      /<span class="stat-value">(?:&lt;|<)1\.5s<\/span>\s*<span class="stat-label">local STT<\/span>/,
    );

    expect(html).toContain("qa_voice_announce");
    expect(html).toContain("qa_voice_brief");
    expect(html).toContain("qa_voice_ask");
    expect(html).toContain("Done. Three files changed, 546 tests passing.");

    expect(html).not.toContain('<div class="setup-code" onclick=');
    expect(html).not.toContain('<div class="install-cmd" onclick=');
    expect(html).toMatch(
      /<button type="button" class="setup-code"[^>]*aria-label="Copy bun add -g voicelayer-mcp command"[^>]*data-copy="bun add -g voicelayer-mcp">/,
    );
    expect(html).toMatch(
      /<button type="button" class="install-cmd"[^>]*aria-label="Copy bun add -g voicelayer-mcp command"[^>]*data-copy="bun add -g voicelayer-mcp">/,
    );

    expect(html).toContain(".skip-link:focus-visible");
    expect(html).toMatch(
      /\.logo:focus-visible,\s*\.nav-right a:focus-visible,\s*\.btn:focus-visible,\s*\.setup-code:focus-visible,\s*\.install-cmd:focus-visible,\s*\.footer-left a:focus-visible,\s*\.footer-right a:focus-visible/,
    );

    expect(html).toMatch(
      /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*\.cursor-blink[\s\S]*\.reveal[\s\S]*transition: none !important;/,
    );
    expect(html).not.toContain("while (true)");
    expect(html).toContain("setInterval(");
    expect(html).toContain("clearInterval(");
    expect(html).toContain("visibilitychange");

    expect(html).toMatch(/\.hero::before\s*\{[\s\S]*width:\s*clamp\(/);
    expect(html).toMatch(/\.hero::before\s*\{[\s\S]*height:\s*clamp\(/);
    expect(html).toContain("@media (max-width: 1024px)");
    expect(html).toContain("@media (max-width: 375px)");

    expect(html).toMatch(
      /\.voicebar-transcript-label\s*\{[\s\S]*font-size:\s*12px;/,
    );
    expect(html).toMatch(/\.vdemo-status\s*\{[\s\S]*font-size:\s*12px;/);
    expect(html).toMatch(/\.vdemo-voice-label\s*\{[\s\S]*font-size:\s*12px;/);
    expect(html).toMatch(/\.vdemo-meta\s*\{[\s\S]*font-size:\s*12px;/);
    expect(html).toMatch(/\.vdemo-statusbar\s*\{[\s\S]*font-size:\s*12px;/);
    expect(html).toMatch(/\.section-heading\s*\{[\s\S]*text-wrap:\s*balance;/);
    expect(html).toMatch(/\.cta-heading\s*\{[\s\S]*text-wrap:\s*balance;/);
    expect(html).toMatch(/h1\s*\{[\s\S]*text-wrap:\s*balance;/);

    expect(html).not.toContain('style="margin-top:16px"');
    expect(html).toContain('class="section-label setup-label"');
  });
});
