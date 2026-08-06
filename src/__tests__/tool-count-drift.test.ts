import { describe, expect, it } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

type Surface = { path: string; text: string };
type ToolClaim = { path: string; line: number; count: number; text: string };

const registrationPath = "src/mcp-tools.ts";
const documentedPaths = [
  "README.md",
  "docs/tools-reference.md",
  "src/mcp-server.ts",
];
const repositoryRoot = import.meta.dir.replace(/\/src\/__tests__$/, "");

function lineNumber(text: string, offset: number): number {
  return text.slice(0, offset).split("\n").length;
}

function withoutHistoricalBlocks(text: string): string {
  const lines = text.split("\n");
  let historicalLevel: number | undefined;

  return lines
    .map((line) => {
      const heading = /^(#{1,6})\s+/.exec(line);
      if (heading) {
        const level = heading[1].length;
        if (historicalLevel !== undefined && level <= historicalLevel) {
          historicalLevel = undefined;
        }
        if (
          /(?:20\d{2}|release notes?|changelog|history)/i.test(line)
        ) {
          historicalLevel = level;
        }
      }
      return historicalLevel === undefined ? line : "";
    })
    .join("\n");
}

function enumerateTools(source: string): number {
  return (source.match(/^\s*name:\s*["'`][^"'`]+["'`]/gm) ?? []).length;
}

function findClaims(surface: Surface): ToolClaim[] {
  const text = withoutHistoricalBlocks(surface.text);
  const claims: ToolClaim[] = [];

  // Covers prose such as "2 MCP tools" and "2 tools", plus badge URLs such
  // as "MCP%20tools-2". CHANGELOG.md is intentionally not a surface: dated
  // historical records are not current claims.
  const claimPatterns = [
    /(\d+)(?: |%20)(?:MCP )?tools\b/gi,
    /MCP(?: |%20)tools-(\d+)/gi,
  ];

  for (const pattern of claimPatterns) {
    for (const match of text.matchAll(pattern)) {
      claims.push({
        path: surface.path,
        line: lineNumber(surface.text, match.index ?? 0),
        count: Number(match[1]),
        text: match[0],
      });
    }
  }
  return claims;
}

async function readSurfaces(root: string): Promise<Surface[]> {
  return Promise.all(
    documentedPaths.map(async (path) => ({
      path,
      text: await Bun.file(`${root}/${path}`).text(),
    })),
  );
}

export async function assertToolCountTruth(root: string): Promise<void> {
  const registration = await Bun.file(`${root}/${registrationPath}`).text();
  const expected = enumerateTools(registration);
  const surfaces = await readSurfaces(root);
  const claims = surfaces.flatMap(findClaims);

  if (
    process.env.VOICELAYER_TOOL_COUNT_MUTATION === "1" &&
    root === repositoryRoot
  ) {
    const badge = claims.find(
      (claim) => claim.path === "README.md" && claim.text.includes("tools-2"),
    );
    if (badge) badge.count += 1;
  }

  const mismatches = claims.filter((claim) => claim.count !== expected);
  if (mismatches.length > 0) {
    throw new Error(
      mismatches
        .map(
          (claim) =>
            `${claim.path}:${claim.line} claims ${claim.count}; registration enumerates ${expected}`,
        )
        .join("\n"),
    );
  }
}

describe("tool-count drift guard", () => {
  it("keeps every current documented tool count equal to registration", async () => {
    await assertToolCountTruth(repositoryRoot);
  });

  it("goes red when a fixture count is mutated", async () => {
    const fixture = await mkdtemp(join(tmpdir(), "voicelayer-tool-count-"));
    await Bun.write(`${fixture}/${registrationPath}`, await Bun.file(registrationPath).text());
    await Bun.write(
      `${fixture}/README.md`,
      await Bun.file("README.md").text(),
    );
    await Bun.write(
      `${fixture}/docs/tools-reference.md`,
      await Bun.file("docs/tools-reference.md").text(),
    );
    await Bun.write(`${fixture}/src/mcp-server.ts`, await Bun.file("src/mcp-server.ts").text());

    await expect(assertToolCountTruth(fixture)).resolves.toBeUndefined();
    const mutated = (await Bun.file(`${fixture}/README.md`).text()).replace(
      "MCP%20tools-2",
      "MCP%20tools-3",
    );
    await Bun.write(`${fixture}/README.md`, mutated);
    await expect(assertToolCountTruth(fixture)).rejects.toThrow(
      "README.md",
    );
  });
});
