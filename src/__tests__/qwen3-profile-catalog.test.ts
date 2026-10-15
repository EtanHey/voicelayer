import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, truncateSync, writeFileSync } from "fs";
import { join } from "path";
import { availableTTSVoices } from "../tts-controls-status";
import { resolveSpeakProfile } from "../tts-settings";
import { TEST_TMP } from "./setup/test-tmp";

const homes: string[] = [];
afterEach(() => { for (const home of homes.splice(0)) rmSync(home, {recursive:true, force:true}); });
function fixture() {
  const home = mkdtempSync(join(TEST_TMP, "ben-catalog-"));
  homes.push(home);
  const directory = join(home, ".voicelayer/voices/ben-c1");
  mkdirSync(directory, {recursive:true});
  const wav = join(directory, "ref.wav");
  writeFileSync(wav, Buffer.from("RIFF synthetic reference"));
  writeFileSync(join(directory, "ref.txt"), "Synthetic reference transcript.");
  const env = {HOME:home, VOICELAYER_TTS_SETTINGS_PATH:join(home, "settings.json")};
  const profile = (clip = "~/.voicelayer/voices/ben-c1/ref.wav", text = "Synthetic reference transcript.") =>
    writeFileSync(join(directory, "profile.yaml"), `name: ben-c1\nprofile_id: ben-c1\nspeaker: Ben\naccepted: true\naliases:\n  - ben\nengine: qwen3-tts\nreference_clip: ${clip}\nreference_text: "${text}"\nfallback: en-US-AndrewMultilingualNeural\n`);
  return {home, directory, wav, env, profile};
}
function ben(env: {HOME:string}) { return availableTTSVoices(env).filter(v => v.voice === "ben-c1"); }

test("WAV and TXT without a profile never advertise Ben", () => {
  expect(ben(fixture().env)).toEqual([]);
});
test("missing, empty and whitespace transcripts never advertise Ben", () => {
  for (const text of ["", "   "]) {
    const f = fixture(); f.profile(undefined, text);
    expect(ben(f.env)).toEqual([]);
  }
  const f = fixture();
  writeFileSync(join(f.directory, "profile.yaml"), "name: ben-c1\naccepted: true\nreference_clip: ~/.voicelayer/voices/ben-c1/ref.wav\n");
  expect(ben(f.env)).toEqual([]);
});
test("missing, outside-root, escaped, non-file, empty and oversize WAVs never advertise Ben", () => {
  for (const failure of ["missing", "outside", "symlink", "directory", "empty", "oversize"]) {
    const f = fixture(); f.profile();
    if (failure === "outside" || failure === "symlink") {
      const outside = join(f.home, "outside.wav"); writeFileSync(outside, "fixture");
      if (failure === "outside") f.profile(outside);
      else { rmSync(f.wav); symlinkSync(outside, f.wav); }
    } else if (failure === "directory") { rmSync(f.wav); mkdirSync(f.wav); }
    else if (failure === "missing") rmSync(f.wav);
    else truncateSync(f.wav, failure === "empty" ? 0 : 5 * 1024 * 1024 + 1);
    expect(ben(f.env)).toEqual([]);
  }
});
test("accepted single-reference Ben is advertised by stable ID and reacts to asset removal", () => {
  const f = fixture(); f.profile();
  expect(ben(f.env)).toEqual([{engine:"clone", voice:"ben-c1"}]);
  rmSync(f.wav);
  expect(ben(f.env)).toEqual([]);
  writeFileSync(f.wav, "restored fixture");
  expect(ben(f.env)).toEqual([{engine:"clone", voice:"ben-c1"}]);
});
test("unaccepted, superseded, mismatched and wrong-engine profiles stay unavailable", () => {
  for (const [before, after] of [["accepted: true", "accepted: false"], ["profile_id: ben-c1", "profile_id: ben-c2"],
    ["engine: qwen3-tts", "engine: f5-tts"], ["accepted: true", "accepted: true\nsuperseded_by: ben-c2"]]) {
    const f = fixture(); f.profile();
    const path = join(f.directory, "profile.yaml");
    writeFileSync(path, readFileSync(path, "utf8").replace(before!, after!));
    expect(ben(f.env)).toEqual([]);
  }
});
test("ready Ben alias and atomic selection survive a fresh process without changing rate or threshold", () => {
  const f = fixture(); f.profile();
  writeFileSync(f.env.VOICELAYER_TTS_SETTINGS_PATH, JSON.stringify({profiles:{short:{engine:"clone",voice:"Ben",rate:"+20%"}},short_limit_chars:650}));
  expect(resolveSpeakProfile("short", "", f.env)).toMatchObject({engine:"clone",voice:"ben-c1",rate:"+20%"});
  const run = (script: string) => {
    const child = Bun.spawnSync([process.execPath, "-e", script], {cwd:process.cwd(), env:{...process.env,...f.env}, stdout:"pipe",stderr:"pipe"});
    expect(child.exitCode).toBe(0);
    return JSON.parse(child.stdout.toString());
  };
  expect(run(`import {loadProfile} from './src/tts/qwen3'; import {setTTSProfile} from './src/tts-settings'; setTTSProfile('short',{engine:'clone',voice:'ben-c1'}); console.log(JSON.stringify(loadProfile('Ben')));`)).toMatchObject({profile_id:"ben-c1",aliases:["ben"]});
  expect(run(`import {readTTSSettings} from './src/tts-settings'; console.log(JSON.stringify(readTTSSettings()));`)).toMatchObject({profiles:{short:{engine:"clone",voice:"ben-c1",rate:"+20%"}},short_limit_chars:650});
});
