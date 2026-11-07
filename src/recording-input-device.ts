import { fileURLToPath } from "url";
import { z } from "zod";

const deviceSchema = z.object({ name: z.string().trim().min(1), uid: z.string().nullable() });
export type RecordingInputDevice = z.infer<typeof deviceSchema>;
const helperPath = fileURLToPath(new URL("./recording-input-device-helper.ts", import.meta.url));
const testMode = !!process.env.VOICELAYER_TEST_RUN_ROOT || process.env.NODE_ENV === "test";

/** Native metadata lives in a disposable child, never in the capture process. */
export async function snapshotRecordingInputDevice(helper = helperPath): Promise<RecordingInputDevice | null> {
  if ((testMode || process.platform !== "darwin") && helper === helperPath) return null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const child = Bun.spawn([process.execPath, helper], { env: process.env, stdout: "pipe", stderr: "ignore" });
    const timeout = new Promise<null>(resolve => {
      timer = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} resolve(null); }, 500);
    });
    const result = Promise.all([new Response(child.stdout).text(), child.exited]).then(([output, code]) => {
      if (code !== 0) return null;
      const parsed = deviceSchema.safeParse(JSON.parse(output));
      return parsed.success ? parsed.data : null;
    }).catch(() => null);
    return await Promise.race([result, timeout]);
  } catch { return null; }
  finally { clearTimeout(timer); }
}

/** Start before recorder spawn; the first-PCM signal schedules the second child off the reader loop. */
export function startRecordingInputDeviceSnapshots() {
  const opening = snapshotRecordingInputDevice();
  let signal!: (hasPCM: boolean) => void;
  const firstPCM = new Promise<boolean>(resolve => { signal = resolve; });
  const settled = firstPCM.then(async hasPCM => {
    const [before, current] = await Promise.all([opening, hasPCM ? snapshotRecordingInputDevice() : null]);
    return before && current && before.name === current.name && before.uid === current.uid ? before : null;
  });
  return { firstPCM: () => signal(true), finish: () => signal(false), settled };
}
