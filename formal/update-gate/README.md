# First-install update gate (G0)

Base 776982d0 has no update-gate TLA+ model. This adds a focused model; every
existing formal model and mutant is retained unchanged. It models absent-file
availability bootstrap, including a legacy 2.2.58 bundle with no gate. It does
not qualify the entire update controller or a real Homebrew install.

Setup samples stopped owners before and after acquiring its bootstrap mutex,
then calls the same G2/G1 exclusive initializer used by voice startup. Existing
records and sidecars stay authoritative. Faults refuse initialization while G4d
may restore availability without granting update authorization. An observed
OPEN generation 0 is never a verified target SHA or a COMMIT lease.

`Create` abstracts the stopped-owner recheck and G1 publication; `Arrive` tests
an owner appearing between the initial sample and that recheck. Legacy apps do
not honor the mutex, so this is not proof that an arbitrary OS launch cannot
race the final process sample. Post-publication process resampling detects that
case and reports recovery, preserving the gate rather than deleting evidence.

Run on the M1 under the captain lock: `bash formal/update-gate/check.sh`.
The shared runner rejects any mutant which passes or fails the wrong property.

| Property | Exact failing config |
| --- | --- |
| BootstrapOnlyQuiescent | MutantLive |
| BootstrapPreservesEvidence | MutantEvidence |
| BootstrapExclusiveCreate | MutantReplace |
| BootstrapOpenGenerationZero | MutantGeneration |
| FreshInstallCompletes | OldNoBootstrap |

## Old updater / new script upgrade (G1)

`UpgradeSpec` models 2.2.58's still-running updater installing new formula bytes,
then cask replacement/postflight, then the NEW dedupe and autostart scripts.
The old updater starts with either an absent gate or the already OPEN gate
observed in the captain's restored 2.2.58 upgrade path.
Homebrew's stop/delete/move is abstracted by `UpgradeCask`. Cask setup and the
compatibility helpers restore only availability. A lease-holding controller
gets plists only until `UpgradeOwnerRestore`; its COMMITTED gate is retained.
`created` records successful completion of the old updater's whole repair
sequence, so merely starting the app in postflight cannot hide a later missing
SHA refusal. `mutex` represents the live controller for this specification.

| Config | Expected result | Exact property |
| --- | --- | --- |
| UpgradeOld | FAIL: sandbox plus missing target | VoiceBarRunningAfterUpgrade |
| UpgradeFixed | PASS | Both upgrade properties |
| MutantMissingTarget | FAIL: fix sandbox only, remove compatibility | VoiceBarRunningAfterUpgrade |
| MutantUpgradeController | FAIL: remove setup's live-controller startup fence | UpgradeControllerOwnsStartup |

`VoiceBarRunningAfterUpgrade` requires successful old-updater completion,
VoiceBar running, and an OPEN gate. Fairness assumes each installer step runs;
startup actions assume functioning host launchd/LaunchServices outside the
observed sandbox denial. This is an ordering proof, not an installed acceptance
claim or protection for the legacy updater's ungated brew mutation. Every new
property has an exact failing mutant, enforced by the shared check runner.
