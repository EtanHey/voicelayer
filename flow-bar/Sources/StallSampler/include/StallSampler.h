#pragma once
#include <mach/mach.h>
#include <stddef.h>
#include <stdint.h>

/// Walks another thread's frame-pointer chain into `frames` (innermost first) and returns the count.
///
/// The target is suspended only inside this function. Between suspend and resume it makes Mach traps and
/// nothing else: no allocation, no lock, no Objective-C or Swift runtime call, so a target that holds the
/// allocator's lock cannot deadlock the caller. `resume_result` is the result of `thread_resume`
/// (KERN_SUCCESS when the thread was never suspended). Returns 0 for the calling thread.
size_t VoiceBarStallSample(thread_act_t thread, uintptr_t *frames, size_t capacity, kern_return_t *resume_result);
