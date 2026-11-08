import { expect, test } from 'bun:test';
import screens from './fixtures/e2e-2.4/m4-screen.json';

test('M4 measured notch fixture leaves eight points on both physical edges', () => {
  const screen = screens[0];
  const left = screen.auxiliaryTopLeftArea;
  const right = screen.auxiliaryTopRightArea;
  expect(screen.safeAreaTop).toBe(32);
  expect(right.x - (left.x + left.width)).toBe(185);
  const excluded = { left: left.x + left.width - 8, right: right.x + 8 };
  expect(excluded.right - excluded.left).toBe(201);
  expect(excluded.left).toBeGreaterThan(0);
  expect(excluded.right).toBeLessThan(screen.frame.width);
});
