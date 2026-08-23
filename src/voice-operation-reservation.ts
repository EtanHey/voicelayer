export type VoiceOperationReservation = { release: () => void };

let activeStandardVoiceOperations = 0;
let archiveRetranscriptionReserved = false;

function reservationFor(
  kind: "standard" | "archive-retranscription",
): VoiceOperationReservation {
  let released = false;
  return {
    release: () => {
      if (released) return;
      released = true;
      if (kind === "archive-retranscription") {
        archiveRetranscriptionReserved = false;
      } else {
        activeStandardVoiceOperations--;
      }
    },
  };
}

export function reserveStandardVoiceOperation(): VoiceOperationReservation | null {
  if (archiveRetranscriptionReserved) return null;
  activeStandardVoiceOperations++;
  return reservationFor("standard");
}

export function reserveArchiveRetranscription(): VoiceOperationReservation | null {
  if (archiveRetranscriptionReserved || activeStandardVoiceOperations > 0) {
    return null;
  }
  archiveRetranscriptionReserved = true;
  return reservationFor("archive-retranscription");
}
