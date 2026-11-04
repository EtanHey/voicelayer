# Validated TLC artifact

`tlc.lock.json` pins the TLC2 2026.10.30 jar (revision `090e85c`) used by the
formal-model receipts. The upstream `v1.8.0` release asset changed bytes after
validation; issue #677 records why its moving URL cannot be used as the pin.

The `tools-tlc-090e85c` VoiceLayer tools release mirrors those exact bytes with
the upstream MIT license. It is separate from the VoiceBar and npm releases.
The SHA-256 remains
`011267fca25d0752cf18894dd585cd28b96960c112ea8a20b823ea770e7e10cd`.
`setup-tlc.py` checks both cached and downloaded bytes before `tlc.sh` runs Java.
