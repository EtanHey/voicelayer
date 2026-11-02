#include "HotkeyAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>

// The event tap must never wait for a main-thread lock, including under paging.
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "hotkey snapshots require lock-free integers");
struct VoiceBarHotkeyAtomic { _Atomic(unsigned int) value; };
VoiceBarHotkeyAtomic *VoiceBarHotkeyAtomicCreate(uint32_t value) {
    VoiceBarHotkeyAtomic *state = malloc(sizeof(*state));
    if (state) atomic_init(&state->value, value);
    return state;
}
void VoiceBarHotkeyAtomicDestroy(VoiceBarHotkeyAtomic *state) { free(state); }
uint32_t VoiceBarHotkeyAtomicLoad(const VoiceBarHotkeyAtomic *state) {
    return atomic_load_explicit(&state->value, memory_order_acquire);
}
void VoiceBarHotkeyAtomicStore(VoiceBarHotkeyAtomic *state, uint32_t value) {
    atomic_store_explicit(&state->value, value, memory_order_release);
}
