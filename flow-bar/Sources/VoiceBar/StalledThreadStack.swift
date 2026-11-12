import Darwin
import Foundation
import StallSampler

/// The call stack of another thread in this process, as function names. Off unless
/// `voicebar.diagnostics.stallStacks` is set. Reads return addresses only: never arguments, locals, text,
/// keys or audio.
enum StalledThreadStack {
    /// `defaults write com.voicelayer.voicebar voicebar.diagnostics.stallStacks -bool YES`
    static let enabledDefaultsKey = "voicebar.diagnostics.stallStacks"

    struct Sample: Equatable {
        var addresses: [UInt]
        /// `thread_resume` failed: the sampled thread may still be stopped. The caller logs it.
        var resumeFailure: kern_return_t?
    }

    struct Location: Equatable {
        var image: String?
        var imageBase: UInt?
        var symbol: String?
        var symbolBase: UInt?
    }

    /// Call on the thread to be watched; the port stays valid for the life of that thread.
    static func currentThreadPort() -> thread_act_t { pthread_mach_thread_np(pthread_self()) }

    /// Return addresses, innermost first. The buffer is allocated before the thread stops and the stop,
    /// walk and resume all happen inside one C function (`VoiceBarStallSample`).
    static func sample(_ thread: thread_act_t, maxFrames: Int = 40) -> Sample {
        guard maxFrames > 0 else { return Sample(addresses: [], resumeFailure: nil) }
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer { buffer.deallocate() }
        var resumed: kern_return_t = KERN_SUCCESS
        let count = VoiceBarStallSample(thread, buffer, maxFrames, &resumed)
        return Sample(addresses: Array(UnsafeBufferPointer(start: buffer, count: min(count, maxFrames))),
                      resumeFailure: resumed == KERN_SUCCESS ? nil : resumed)
    }

    /// `image:symbol+offset`, or `image+0x<image-relative address>` when the frame has no symbol, so it can
    /// still be symbolicated against that build. Image paths are reduced to their basename.
    static func describe(_ addresses: [UInt], lookup: (UInt) -> Location? = dynamicLocation) -> [String] {
        addresses.map { address in
            guard let location = lookup(address), let image = location.image else {
                return "0x" + String(address, radix: 16)
            }
            if let symbol = location.symbol, let base = location.symbolBase, address >= base {
                return "\(image):\(symbol)+\(address - base)"
            }
            if let base = location.imageBase, address >= base {
                return "\(image)+0x" + String(address - base, radix: 16)
            }
            return "\(image)@0x" + String(address, radix: 16)
        }
    }

    static func dynamicLocation(_ address: UInt) -> Location? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return nil }
        return Location(
            image: info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent },
            imageBase: info.dli_fbase.map { UInt(bitPattern: $0) },
            symbol: info.dli_sname.map { String(cString: $0) },
            symbolBase: info.dli_saddr.map { UInt(bitPattern: $0) })
    }

    /// The watchdog's stack source: nothing unless the diagnostics key is on, read at each capture so it can
    /// be switched without a relaunch.
    static func frames(of thread: thread_act_t, defaults: UserDefaults,
                       log: (String) -> Void = { NSLog("%@", $0) }) -> [String] {
        guard defaults.bool(forKey: enabledDefaultsKey) else { return [] }
        let sample = sample(thread)
        if let failure = sample.resumeFailure {
            log("[VoiceBar][responsiveness] stack_sampler thread_resume failed kr=\(failure)")
        }
        return describe(sample.addresses)
    }
}
