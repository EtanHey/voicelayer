#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct VoiceBarHotkeyAtomic VoiceBarHotkeyAtomic;
VoiceBarHotkeyAtomic *VoiceBarHotkeyAtomicCreate(uint32_t value);
void VoiceBarHotkeyAtomicDestroy(VoiceBarHotkeyAtomic *state);
uint32_t VoiceBarHotkeyAtomicLoad(const VoiceBarHotkeyAtomic *state);
void VoiceBarHotkeyAtomicStore(VoiceBarHotkeyAtomic *state, uint32_t value);
