import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand, polishTransitionsSettled } from "../socket-handlers";
import * as input from "../input";
import * as tts from "../tts";
import * as booking from "../session-booking";
import * as polishServer from "../stt-polish-server";

describe("set_processing_setting (P1)", () => {
  const spies: Array<ReturnType<typeof spyOn>> = [];
  const dir = join(TEST_TMP, "socket-processing");
  const path = join(dir, "processing-settings.json");
  const savedPath = process.env.VOICELAYER_PROCESSING_SETTINGS_PATH;
  const savedOutro = process.env.VOICELAYER_STT_OUTRO_GATE;

  beforeEach(() => {
    mkdirSync(dir, { recursive: true });
    process.env.VOICELAYER_PROCESSING_SETTINGS_PATH = path;
    delete process.env.VOICELAYER_STT_OUTRO_GATE;
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
  });
  afterEach(() => {
    for (const spy of spies.splice(0)) spy.mockRestore();
    if (savedPath === undefined) delete process.env.VOICELAYER_PROCESSING_SETTINGS_PATH;
    else process.env.VOICELAYER_PROCESSING_SETTINGS_PATH = savedPath;
    if (savedOutro === undefined) delete process.env.VOICELAYER_STT_OUTRO_GATE;
    else process.env.VOICELAYER_STT_OUTRO_GATE = savedOutro;
    rmSync(dir, { recursive: true, force: true });
  });

  test("parses only the four keys with a boolean value", () => {
    expect(parseCommand('{"cmd":"set_processing_setting","key":"outro_gate","value":false,"id":"p1"}'))
      .toEqual({ cmd: "set_processing_setting", key: "outro_gate", value: false, id: "p1" });
    expect(parseCommand('{"cmd":"set_processing_setting","key":"volume","value":true}')).toBeNull();
    expect(parseCommand('{"cmd":"set_processing_setting","key":"smart_chunks","value":"on"}')).toBeNull();
  });

  test("saves the toggle and acks with the fresh polish_controls", async () => {
    const ack = await handleSocketCommand({
      cmd: "set_processing_setting", key: "outro_gate", value: false, id: "p-accept",
    });
    expect(ack).toMatchObject({
      type: "ack", command: "set_processing_setting", outcome: "accept", id: "p-accept",
      polish_controls: { outro_gate: { source: "settings", raw: null, effective: false } },
    });
    expect(JSON.parse(readFileSync(path, "utf8")).outro_gate).toBe(false);
  });

  test("is rejected while busy and writes nothing", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("recording"));
    const ack = await handleSocketCommand({
      cmd: "set_processing_setting", key: "smart_chunks", value: true, id: "p-busy",
    });
    expect(ack).toMatchObject({ outcome: "reject" });
    expect(() => readFileSync(path, "utf8")).toThrow();
  });

  test("is rejected when the environment sets the flag, naming the variable", async () => {
    process.env.VOICELAYER_STT_OUTRO_GATE = "1";
    const ack = await handleSocketCommand({
      cmd: "set_processing_setting", key: "outro_gate", value: false, id: "p-env",
    });
    expect(ack).toMatchObject({ outcome: "reject", reason: "set by VOICELAYER_STT_OUTRO_GATE" });
  });

  test("turning Polish off stops the polish server; on starts it", async () => {
    const stop = spyOn(polishServer, "stopSTTPolishServerAndWait").mockResolvedValue(undefined);
    const ensure = spyOn(polishServer, "ensureSTTPolishServer").mockResolvedValue({ status: "disabled" } as never);
    spies.push(stop, ensure);

    await handleSocketCommand({ cmd: "set_processing_setting", key: "model_polish", value: false, id: "p-off" });
    await polishTransitionsSettled();
    expect(stop).toHaveBeenCalledTimes(1);
    expect(ensure).toHaveBeenCalledTimes(1);

    await handleSocketCommand({ cmd: "set_processing_setting", key: "model_polish", value: true, id: "p-on" });
    await polishTransitionsSettled();
    expect(stop).toHaveBeenCalledTimes(1);
    expect(ensure).toHaveBeenCalledTimes(2);
  });

  test("a rapid off then on starts the server only after the old one has stopped (#146 round 2)", async () => {
    const order: string[] = [];
    let finishStop!: () => void;
    spies.push(spyOn(polishServer, "stopSTTPolishServerAndWait").mockImplementation(() => {
      order.push("stop");
      return new Promise<void>((resolve) => { finishStop = () => { order.push("stopped"); resolve(); }; });
    }));
    spies.push(spyOn(polishServer, "ensureSTTPolishServer").mockImplementation(async () => {
      order.push("ensure");
      return { status: "ready" } as never;
    }));

    await handleSocketCommand({ cmd: "set_processing_setting", key: "model_polish", value: false, id: "p-rapid-off" });
    await handleSocketCommand({ cmd: "set_processing_setting", key: "model_polish", value: true, id: "p-rapid-on" });
    await Bun.sleep(10);
    expect(order).toEqual(["stop"]);
    finishStop();
    await polishTransitionsSettled();
    expect(order).toEqual(["stop", "stopped", "ensure", "ensure"]);
  });
});
