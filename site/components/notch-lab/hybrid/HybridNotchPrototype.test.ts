import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const componentPath = join(import.meta.dir, "HybridNotchPrototype.tsx");
const materialPath = join(import.meta.dir, "unified-glass.module.css");

describe("unified glass hybrid prototype source contract", () => {
  test("is an editable Tailwind and Framer Motion prototype", () => {
    expect(existsSync(componentPath)).toBe(true);

    const source = readFileSync(componentPath, "utf8");
    expect(source).toContain('from "framer-motion"');
    expect(source).toContain("AnimatePresence");
    expect(source).toContain("motion.div");
    expect(source).toContain("HYBRID_GEOMETRY");
    expect(source).toContain("backdrop-blur");
    expect(source).toContain("Replay morph");
  });

  test("offers the three classy idle-hover actions and wires mic to recording", () => {
    if (!existsSync(componentPath)) {
      expect(existsSync(componentPath)).toBe(true);
      return;
    }
    const source = readFileSync(componentPath, "utf8");
    expect(source).toContain('label="Open history"');
    expect(source).toContain('label="Open dictionary"');
    expect(source).toContain('label="Start recording"');
    expect(source).toContain('selectState("recording")');
    expect(source).toContain("onMouseEnter");
    expect(source).toContain("onMouseLeave");
  });

  test("puts mic in the leading hover wing and history plus dictionary in the trailing wing", () => {
    const source = readFileSync(componentPath, "utf8");
    expect(source).toContain('data-launcher-wing="leading"');
    expect(source).toContain('data-launcher-wing="trailing"');
    expect(source.indexOf('label="Start recording"')).toBeLessThan(
      source.indexOf('label="Open history"'),
    );
    expect(source.indexOf('label="Open history"')).toBeLessThan(
      source.indexOf('label="Open dictionary"'),
    );
  });

  test("uses a continuous material without a framed teleprompter card", () => {
    expect(existsSync(materialPath)).toBe(true);
    if (!existsSync(componentPath) || !existsSync(materialPath)) return;

    const component = readFileSync(componentPath, "utf8");
    const material = readFileSync(materialPath, "utf8");
    expect(component).not.toContain("innerFrame");
    expect(material).not.toContain(".innerFrame");
    expect(material).toContain(".blackToGlassFadeLeft");
    expect(material).toContain(".blackToGlassFadeRight");
    expect(material).toContain(".continuousGlass");
  });

  test("mirrors a dedicated fade-safe inset across teleprompter wings", () => {
    const source = readFileSync(componentPath, "utf8");
    expect(source).toContain("fadeSafeInnerPadding");
    expect(source).toMatch(
      /paddingRight:[\s\S]{0,120}\? fadeSafeInnerPadding/,
    );
    expect(source).toMatch(
      /paddingLeft:[\s\S]{0,120}\? fadeSafeInnerPadding/,
    );
    expect(source).toContain("HYBRID_MATERIAL.wingOuterPaddingPx");
  });

  test("renders every top wing through one shared liquid-glass component", () => {
    const source = readFileSync(componentPath, "utf8");
    const componentStart = source.indexOf("function GlassWing(");
    const prototypeStart = source.indexOf("export function HybridNotchPrototype()");
    const wingComponent = source.slice(componentStart, prototypeStart);

    expect(componentStart).toBeGreaterThan(-1);
    expect(source).toContain("GLASS_MATERIAL_CLASS");
    expect(wingComponent).toContain("GLASS_MATERIAL_CLASS");
    expect(source.match(/\$\{GLASS_MATERIAL_CLASS\}/g)?.length).toBe(2);
    expect(wingComponent).toContain("styles.continuousGlass");
    expect(wingComponent).toContain("blackToGlassFade");
    expect(wingComponent).toContain("border-y");
    expect(source.match(/<GlassWing/g)?.length).toBe(2);
    expect(source).not.toContain("compactLeadingWingOutlineClass");
    expect(source).not.toContain("compactTrailingWingOutlineClass");
  });

  test("folds the panel and wings away instead of unmounting them in one frame", () => {
    const source = readFileSync(componentPath, "utf8");
    expect(source).toContain("scaleY: 0.02");
    expect(source).toContain("scaleX: 0.08");
    expect(source.match(/<AnimatePresence/g)?.length).toBeGreaterThanOrEqual(5);
  });
});
