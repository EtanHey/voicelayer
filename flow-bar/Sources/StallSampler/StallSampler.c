#include "StallSampler.h"
#include <pthread.h>

// Pointer-authentication bits live above the 47-bit user address space.
#define VB_ADDRESS_MASK ((uintptr_t)0x00007FFFFFFFFFFFULL)

static int vb_read_pair(uintptr_t address, uintptr_t pair[2]) {
    vm_size_t got = 0;
    // Fails instead of faulting when a frame pointer is garbage.
    kern_return_t status = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(uintptr_t) * 2,
                                             (vm_address_t)pair, &got);
    return status == KERN_SUCCESS && got == sizeof(uintptr_t) * 2;
}

size_t VoiceBarStallSample(thread_act_t thread, uintptr_t *frames, size_t capacity, kern_return_t *resume_result) {
    *resume_result = KERN_SUCCESS;
    if (frames == NULL || capacity == 0 || thread == pthread_mach_thread_np(pthread_self())) return 0;

    // Warm this thread's Mach reply port before the target stops, so nothing is set up while it is stopped.
    uintptr_t warm[2];
    (void)vb_read_pair((uintptr_t)&warm, warm);

    if (thread_suspend(thread) != KERN_SUCCESS) return 0;
    size_t count = 0;
    uintptr_t frame = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t size = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &size) == KERN_SUCCESS) {
        frames[count++] = (uintptr_t)arm_thread_state64_get_pc(state) & VB_ADDRESS_MASK;
        frame = (uintptr_t)arm_thread_state64_get_fp(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t size = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &size) == KERN_SUCCESS) {
        frames[count++] = (uintptr_t)state.__rip;
        frame = (uintptr_t)state.__rbp;
    }
#endif
    while (count < capacity && frame != 0 && (frame & 0xF) == 0) {
        uintptr_t pair[2]; // [0] caller's frame pointer, [1] return address
        if (!vb_read_pair(frame, pair)) break;
        uintptr_t return_address = pair[1] & VB_ADDRESS_MASK;
        if (return_address == 0) break;
        frames[count++] = return_address;
        if (pair[0] <= frame) break; // Stacks grow down: a caller's frame is always higher.
        frame = pair[0];
    }
    *resume_result = thread_resume(thread);
    return count;
}
