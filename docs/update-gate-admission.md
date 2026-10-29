# Daemon/CLI update admission (G2)

Consumes G1's schema and `withUpdateGateLock` unchanged. Native participation is G3; installation is G4. This adapter is not installed-app/runtime proof.

Verified quiescent bootstrap must supply G1's OPEN record and a private 0700 directory at `<gatePath>.admissions`. Production never initializes missing state, reaps old locks or assumes idle. The preload creates synthetic fixtures in its isolated run root only.
Each active entry is a 0600 JSON `{token,pid,incarnation,generation}` record. PID never authorizes reclamation. Registration and drain use G1's mkdir lock and fsync/rename/parent-fsync/F_FULLFSYNC persistence. Only the originating closure releases its exact record. It retries its own release on transient contention; exhausted retries retain the registration, never clear another owner's lock.
Crash leftovers and unconfirmed player/archive completion block preparation until qualified recovery. Queued selections retain their own admission through preparation/start/cancellation. Complete Ask continuations retain admission across prompt, capture, delivery and archive work. Stop/Cancel and Next for already-admitted queued reads remain usable; drain never writes those signals.

Trusted updater API:

- `updateVoiceGate(REQUEST|CANCEL)` closes/reopens the owning precommit generation.
- `acknowledgeVoiceDrain(lease, proof)` returns the matching zero-count acknowledgement only with an empty ledger and current proof.
- `updateVoiceGate(PREPARE|COMMIT, proof)` rechecks the ledger and current proof under the lock. Mutate only for APPLIED COMMIT; UNCHANGED never repeats installation.

Proof must be synchronous and return exactly true after validating live native/daemon incarnations, pending handoffs, archive durability, unregistered competing owners and the staged target. The trusted G3/G4 consumer must supply those probes; missing proof refuses UNKNOWN. Never accept proof assertions from an unauthenticated socket client. Persisted preparation alone cannot authorize commit after restart.

Surface sweep: Entry points — MCP speak/ask/converse, raw socket speech/record/retranscribe/preview/replay/Next, CLI fallback, exported TTS/capture boundaries. Clients — shared handlers cover daemon, standalone and stdio; CLI fallback is also gated. Providers — admission precedes backend selection. Contracts — G1 schema/lock unchanged; ledger format above. Reverse states — focused tests cover closure, UNKNOWN, Ask continuation, background ownership and Stop/Cancel. Connections — host-local persisted registrations cover independent processes; Swift/Bun runtime proof remains G3. Docs — this adapter contract supplements G1's format.

Deferred to lead/G3/G4: native F5/Option+F5/History/external quit, qualified bootstrap/recovery, live identity/target probes, installer and saved-cask hook ordering, full-suite/typecheck, real-client verification. Keep the update button gated until all participants qualify. No app build/install or live gate/socket access was performed here.
