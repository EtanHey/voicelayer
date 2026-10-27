import { getRecordingState } from "./input";
import { getPlaybackQueueDepth } from "./tts";
import { hasActiveVoiceOperation } from "./voice-operation-reservation";
import { isVoiceBooked } from "./session-booking";

export function residencyBusy(): boolean {
  const booking = isVoiceBooked();
  return getRecordingState() !== "idle" ||
    getPlaybackQueueDepth() > 0 || hasActiveVoiceOperation() ||
    (booking.booked && !booking.ownedByUs);
}
