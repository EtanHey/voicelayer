import { dlopen, FFIType, ptr } from "bun:ffi";

// Darwin sys/proc_info.h: PROC_PIDTBSDINFO returns proc_bsdinfo (136 bytes),
// ending in uint64_t pbi_start_tvsec and pbi_start_tvusec at offsets 120/128.
// Unlike ps lstart, this preserves ordering within the install second.
export function darwinProcessStartMs(pid: number): number {
  const library = dlopen("/usr/lib/libproc.dylib", {
    proc_pidinfo: { args: [FFIType.i32, FFIType.i32, FFIType.u64, FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
  });
  try {
    const info = Buffer.alloc(136);
    if (library.symbols.proc_pidinfo(pid, 3, 0, ptr(info), info.length) !== info.length
        || info.readUInt32LE(12) !== pid) throw new Error(`cannot read process ${pid} start time`);
    const seconds = Number(info.readBigUInt64LE(120));
    const micros = Number(info.readBigUInt64LE(128));
    if (!Number.isSafeInteger(seconds) || seconds <= 0 || micros >= 1_000_000) {
      throw new Error(`invalid process ${pid} start time`);
    }
    return seconds * 1000 + micros / 1000;
  } finally {
    library.close();
  }
}
