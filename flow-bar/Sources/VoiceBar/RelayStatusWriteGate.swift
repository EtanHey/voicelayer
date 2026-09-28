/// C13 review (Bugbot on PR #193): the relay status cache has three writers: the Settings refresh, Check shortcut and
/// Set up / Reinstall. A probe started before a setup can finish after it and write the pre-install snapshot over
/// the fresh one. Each probe takes a ticket when it starts; a finished setup invalidates every earlier ticket, and
/// nothing but the setup itself writes while one runs.
struct RelayStatusWriteGate {
    private var generation = 0

    func ticket() -> Int {
        generation
    }

    mutating func setupFinished() {
        generation += 1
    }

    func mayWrite(_ ticket: Int, setupInFlight: Bool) -> Bool {
        !setupInFlight && ticket == generation
    }
}
