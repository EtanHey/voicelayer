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
vl_update_gate() { echo gate >> "$CALLS"; bash -c 'echo "pin=\${VOICELAYER_UPDATE_PREFETCHED_CASK_VERSION:-unset}"' >> "$CALLS"; export VOICELAYER_INSTALL_OPERATION=stub; }
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
  // The gated run is a child process: the version the preflight fetched must be exported to it.
  expect(lines).toContain('pin=2.4.1');
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

test('changed offer after prefetch refuses before mutation', () => {
  const body = `source "$1"; bcs_update_gate() { :; }; bcs_require_brew() { :; }; bcs_tap_update() { :; }; bcs_drift_state() { echo absent; }; bcs_app_bundle_version() { echo 2.4.0; }; bcs_tap_offered_version() { echo 2.4.2; }; bcs_brew_run() { echo install; }; bcs_sync_cask tap/voicebar /nonexistent /nonexistent`;
  const r = Bun.spawnSync(['bash', '-c', body, '_', join(import.meta.dir, '../../scripts/lib/brew-cask-sync.sh')], {env: {...process.env, VOICELAYER_UPDATE_PREFETCHED_CASK_VERSION: '2.4.1'}, stdout:'pipe', stderr:'pipe'});
  expect(r.exitCode).not.toBe(0); expect(r.stdout.toString()).not.toContain('install');
});
test('unreadable existing app refuses before gate', () => {
  const body = `source "$1"; VOICEBAR_CANONICAL_APP="$2"; bcs_preflight_tap_refresh() { :; }; bcs_tap_repo_path() { echo /stub; }; bcs_tap_offered_version() { echo 2.4.1; }; bcs_app_bundle_version() { :; }; preflight_brew() { :; }; preflight_cask_download`;
  const r = Bun.spawnSync(['bash','-c',body,'_',script,import.meta.dir], {env: {...process.env}, stdout:'pipe',stderr:'pipe'});
  expect(r.exitCode).not.toBe(0);
});

function shell(body: string) {
  return Bun.spawnSync(['bash','-c', `source "$1"; ${body}`, '_', script], {env:{...process.env}, stdout:'pipe',stderr:'pipe'});
}
test('missing brew simulation succeeds', () => {
  const r = shell('bcs_brew_bin() { return 1; }; bcs_caller_simulates_commands() { return 0; }; preflight_cask_download');
  expect(r.exitCode).toBe(0);
});
test('installed older formula is fetched', () => {
  const r = shell('bcs_brew_bin() { echo /stub; }; bcs_preflight_tap_refresh() { :; }; bcs_tap_repo_path() { echo /stub; }; bcs_tap_offered_version() { echo 2.4.1; }; bcs_app_bundle_version() { echo 2.4.0; }; bcs_formula_version() { echo 2.4.0; }; formula_offered_version() { echo 2.4.1; }; preflight_brew() { echo "$*"; }; preflight_cask_download');
  expect(r.exitCode).toBe(0); expect(r.stdout.toString()).toContain('fetch --formula');
});
test('real preflight tap refresh pulls branch', () => {
  const root = mkdtempSync(join(bundleFixtureRoot(), 'tap-')); const git = join(root, 'git');
  Bun.spawnSync(['mkdir','-p',join(root,'.git')], {env:process.env});
  writeFileSync(git, '#!/bin/bash\necho "$*"\n'); chmodSync(git,0o755);
  const r = shell(`PATH="${root}:$PATH"; bcs_tap_repo_path() { echo "${root}"; }; bcs_preflight_tap_refresh tap`);
  expect(r.exitCode).toBe(0); expect(r.stdout.toString()).toContain('pull --ff-only origin main');
  rmSync(root,{recursive:true,force:true});
});
test('preflight failures explain refusal', () => {
  for (const setup of [
    'bcs_tap_repo_path() { return 1; }; bcs_preflight_tap_refresh tap',
    'bcs_brew_bin() { echo /stub; }; bcs_preflight_tap_refresh() { :; }; bcs_tap_repo_path() { return 1; }; preflight_cask_download',
    'bcs_brew_bin() { echo /stub; }; bcs_preflight_tap_refresh() { :; }; bcs_tap_repo_path() { echo /stub; }; bcs_tap_offered_version() { echo 2.4.1; }; bcs_app_bundle_version() { echo 2.4.0; }; preflight_brew() { :; }; bcs_formula_version() { echo 2.4.0; }; formula_offered_version() { :; }; preflight_cask_download'
  ]) { const r = shell(setup); expect(r.exitCode).not.toBe(0); expect(r.stderr.toString()).toContain('refusing update before stopping VoiceBar'); }
});
