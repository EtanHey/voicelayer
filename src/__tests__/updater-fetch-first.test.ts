import { test, expect } from 'bun:test';
import { mkdtempSync, writeFileSync, chmodSync, readFileSync, rmSync } from 'fs';
import { join } from 'path';
import { bundleFixtureRoot } from './setup/bundle-fixtures';

const script = process.env.UPDATER_TEST_SCRIPT ?? join(import.meta.dir, '../../scripts/voicelayer-update.sh');
function exercise(offer: string, fail = false, dry = false) {
  const root = mkdtempSync(join(bundleFixtureRoot(), 'fetch-first-'));
  const calls = join(root, 'calls');
  const brew = join(root, 'brew');
  writeFileSync(calls, '');
  writeFileSync(brew, `#!/bin/bash\nprintf '%s\n' "$*" >> "$CALLS"\n[[ "$1" != fetch || "$FAIL" != 1 ]]\n`);
  chmodSync(brew, 0o755);
  const body = `source "$1"
print_plan() { :; }; validate_args() { :; }; ensure_command() { :; }
detect_install_type() { echo git-checkout; }; voicebar_app_update_mode() { echo cask-sync; }
bcs_tap_repo_path() { echo /stub/tap; }; bcs_preflight_tap_refresh() { :; }
vl_update_gate() { echo gate >> "$CALLS"; export VOICELAYER_INSTALL_OPERATION=stub; }
update_package() { :; }; update_voicebar_app() { bcs_brew install --cask example; }
update_formula() { :; }; run_qwen3_model_step() { :; }; sync_personal_data() { :; }
repair_and_verify_voicebar_hotkey_path() { :; }; verify_voicebar_stack() { :; }
main ${dry ? '--dry-run' : ''}`;
  const result = Bun.spawnSync(['bash', '-c', body, '_', script], { env: { ...process.env,
    BREW_CASK_SYNC_BREW_BIN: brew, BREW_CASK_SYNC_TEST_APP_VERSION: '2.4.0',
    BREW_CASK_SYNC_TEST_OFFERED_VERSION: offer, BREW_CASK_SYNC_TEST_FORMULA_VERSION: '',
    CALLS: calls, FAIL: fail ? '1' : '0' }, stdout: 'pipe', stderr: 'pipe' });
  const output = result.stdout.toString() + result.stderr.toString();
  const lines = readFileSync(calls, 'utf8').trim().split('\n').filter(Boolean);
  rmSync(root, { recursive: true, force: true });
  return { result, output, lines };
}
test('fetch precedes gate and install', () => {
  const { result, lines } = exercise('2.4.1');
  expect(result.exitCode).toBe(0);
  expect(lines.findIndex(x => x.startsWith('fetch --cask'))).toBeGreaterThanOrEqual(0);
  expect(lines.findIndex(x => x.startsWith('fetch --cask'))).toBeLessThan(lines.indexOf('gate'));
  expect(lines.indexOf('gate')).toBeLessThan(lines.findIndex(x => x.startsWith('install --cask')));
});
test('refuses downgrade before gate', () => {
  const { result, output, lines } = exercise('2.2.61');
  expect(result.exitCode).not.toBe(0); expect(output).toContain('2.4.0'); expect(output).toContain('2.2.61');
  expect(lines).toEqual([]);
});
test('failed fetch refuses before gate', () => {
  const { result, lines } = exercise('2.4.1', true);
  expect(result.exitCode).not.toBe(0); expect(lines).not.toContain('gate');
});
test('equal offer proceeds', () => { expect(exercise('2.4.0').lines).toContain('gate'); });
test('dry run does not fetch', () => { expect(exercise('2.4.1', false, true).lines).toEqual([]); });
