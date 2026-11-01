# Recognizer residency admission model
The finite TLA+ abstraction checks one-model admission through picker cleanup/startup, symmetric previous-engine restoration, and legacy W load. Fixed:208distinctstates,507generated,depth24,OneModel/UnknownBlocks hold. OldLegacyRace and OldRecoveryRace each produce OneModel counterexamples (raw TLC logs/traces in the lab report).

Source joins: LegacyStart -> beginRecognizerMaintenance/withRecognizerMaintenance; BeginPicker -> beginRecognizerTransition; StopP/StopW -> selectRecognizer positive cleanup and busy rechecks; RecoverPrevious/RequestStart -> recognizerRecovery plus getBackend actual restored-provider reuse; UnknownCleanup/ConfirmedCleanup -> dedicated cleanup barrier/positive confirmation.

This is an order-of-events abstraction, not extracted source equivalence or a proof of all runtime behavior. In-flight provider error cleanup, native process/EOF facts, timing, decode quality and capture device behavior are outside it. Actual daemon and focused source evidence remain separate. No liveness assertion is made.

Run TLC with Fixed.cfg; negative configurations preserve two historical race witnesses. The macOS java launcher had no registered JRE; existing /opt/homebrew/opt/openjdk/bin/java performed the runs. No Java install was made.
