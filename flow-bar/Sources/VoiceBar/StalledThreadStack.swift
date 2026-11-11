import Darwin
import Foundation

/// The call stack of another thread in this process, as function names. Used once per long stall so the log
/// says where the loop was stuck. Reads return addresses only: never arguments, locals, text, keys or audio.
enum StalledThreadStack {
    /// Call on the thread to be watched; the port stays valid for the life of that thread.
    static func currentThreadPort() -> thread_act_t { pthread_mach_thread_np(pthread_self()) }

    /// Return addresses, innermost first. The thread is suspended only for the frame walk, which neither
    /// allocates nor locks (the suspended thread may hold the allocator's lock).
    static func addresses(of thread: thread_act_t, maxFrames: Int = 40) -> [UInt] {
        #if arch(arm64)
        guard thread != pthread_mach_thread_np(pthread_self()), maxFrames > 0 else { return [] }
        var frames = [UInt](repeating: 0, count: maxFrames)
        var count = 0
        frames.withUnsafeMutableBufferPointer { buffer in
            guard thread_suspend(thread) == KERN_SUCCESS else { return }
            defer { thread_resume(thread) }
            var state = arm_thread_state64_t()
            var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let read = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) {
                    thread_get_state(thread, ARM_THREAD_STATE64, $0, &size)
                }
            }
            guard read == KERN_SUCCESS else { return }
            buffer[0] = strip(UInt(state.__pc)); count = 1
            var frame = UInt(state.__fp)
            while count < buffer.count, frame != 0, frame & 0xF == 0 {
                // [frame] = caller's frame pointer, [frame + 8] = return address. vm_read_overwrite fails
                // instead of faulting when a frame pointer is garbage.
                var pair: (UInt, UInt) = (0, 0)
                var got: vm_size_t = 0
                let status = withUnsafeMutablePointer(to: &pair) {
                    vm_read_overwrite(mach_task_self_, vm_address_t(frame), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                      vm_address_t(UInt(bitPattern: $0)), &got)
                }
                guard status == KERN_SUCCESS, got == MemoryLayout<(UInt, UInt)>.size else { break }
                let returnAddress = strip(pair.1)
                guard returnAddress != 0 else { break }
                buffer[count] = returnAddress; count += 1
                guard pair.0 > frame else { break } // Stacks grow down: a caller's frame is always higher.
                frame = pair.0
            }
        }
        return Array(frames.prefix(count))
        #else
        return []
        #endif
    }

    /// `image:symbol+offset`, innermost first. Symbols are left mangled: demangling is the reader's job.
    static func describe(_ addresses: [UInt]) -> [String] {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(address, radix: 16) }
            let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
            guard let name = info.dli_sname, let base = info.dli_saddr else { return image }
            return "\(image):\(String(cString: name))+\(address - UInt(bitPattern: base))"
        }
    }

    /// Pointer-authentication bits live above the 47-bit user address space.
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }
}
