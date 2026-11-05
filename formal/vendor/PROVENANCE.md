# Validated TLC jar

- Artifact: `tla2tools.jar`, 4,504,533 bytes.
- SHA-256: `011267fca25d0752cf18894dd585cd28b96960c112ea8a20b823ea770e7e10cd`.
- Upstream revision: `090e85c31a6d7fb3d34a33a9f1a46310cdc2aa7f` (`090e85c`).
- Manifest build timestamp: `2026-10-30T15:41:39.944Z`.
- Source: the previously validated TLC v1.8.0 cache used for VoiceLayer's formal receipts.
- License: upstream MIT license at that revision, reproduced in `LICENSE.txt`.

The upstream v1.8.0 and rolling GitHub assets are replaced by later builds.
Their current bytes differ from the validated checksum (issue #677).
The fixed CalVer tag `2026.10.30.154139` has no published release asset (HTTP 404).
The exact revision's timestamped Maven artifact
`1.8.0-20261030.155007-117` also differs: upstream strips dependency packages
before publishing to Maven. Its SHA-256 is
`efce0f6fcda8ba7180f3b3bd9b4322ddc28607a7c3709c5dca6a8ab87b45ccbc`.

These checks found no upstream immutable URL serving the validated bytes.
Vendoring preserves the exact jar and embedded notices without rebuilding it,
changing the pin, or publishing a new release. `tlc.lock.json` names the relative
path; `setup-tlc.py` checks the vendor, copied and cached bytes before `tlc.sh`
executes Java. The Actions cache key uses that same artifact SHA-256.

Upstream evidence:
- https://github.com/tlaplus/tlaplus/actions/runs/41080764778
- https://github.com/tlaplus/tlaplus/blob/090e85c31a6d7fb3d34a33a9f1a46310cdc2aa7f/.github/workflows/main.yml#L320-L323
- https://central.sonatype.com/repository/maven-snapshots/org/lamport/tla2tools/1.8.0-SNAPSHOT/tla2tools-1.8.0-20261030.155007-117.jar
