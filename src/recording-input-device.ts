import { dlopen, ptr, read, type Pointer } from "bun:ffi";

export interface RecordingInputDevice {
  name: string;
  uid: string | null;
}

function openAudioProperties() {
  return dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", {
    AudioObjectGetPropertyData: { args: ["u32", "ptr", "u32", "ptr", "ptr", "ptr"], returns: "i32" },
  });
}
function openStrings() {
  return dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", {
    CFStringGetCString: { args: ["ptr", "ptr", "i64", "u32"], returns: "bool" },
    CFRelease: { args: ["ptr"], returns: "void" },
  });
}
let audio: ReturnType<typeof openAudioProperties> | undefined;
let strings: ReturnType<typeof openStrings> | undefined;
const testMode = !!process.env.VOICELAYER_TEST_RUN_ROOT || process.env.NODE_ENV === "test";

/** Read the same CoreAudio default input that the microphone picker sets and sox opens.
 * Property reads only: never opens a microphone, changes selection, or caches a device identity.
 */
export function readRecordingInputDevice(): RecordingInputDevice | null {
  if (process.platform !== "darwin" || testMode) return null;
  try {
    const audioProperties = audio ??= openAudioProperties();
    const cfStrings = strings ??= openStrings();
    const get = (object: number, selector: number, output: Uint32Array | BigUint64Array) => {
      const address = new Uint32Array([selector, 0x676c6f62, 0]); // global, main
      const size = new Uint32Array([output.byteLength]);
      return audioProperties.symbols.AudioObjectGetPropertyData(object, ptr(address), 0, null, ptr(size), ptr(output)) === 0;
    };
    const device = new Uint32Array(1);
    if (!get(1, 0x64496e20, device) || !device[0]) return null; // dIn : default input
    const string = (selector: number): string | null => {
      const output = new BigUint64Array(1);
      if (!get(device[0], selector, output)) return null;
      const address = read.ptr(ptr(output));
      if (!address) return null;
      // A successful CoreAudio CFString property read owns this non-null CF pointer.
      const value = address as Pointer;
      try {
        const buffer = Buffer.alloc(4096);
        if (!cfStrings.symbols.CFStringGetCString(value, ptr(buffer), buffer.length, 0x08000100)) return null;
        return buffer.subarray(0, buffer.indexOf(0)).toString("utf8").trim() || null;
      } finally { cfStrings.symbols.CFRelease(value); }
    };
    const name = string(0x6c6e616d); // lnam: kAudioObjectPropertyName
    return name ? { name, uid: string(0x75696420) } : null; // uid : stable device UID
  } catch {
    return null; // Missing metadata must never prevent a capture.
  }
}
