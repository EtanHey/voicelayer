# Lane D: delete a resident recognizer

Checked with the repository's `ResidentRecognizer.tla`, extending the existing
selection/download model with a delete projection. Selection still stops both
owners and loads the selected engine eagerly; the runtime idle default stays 600 s.

Command (run in this directory, substituting each configuration):

```sh
java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC -workers 1 -config FixedDelete.cfg ResidentRecognizer.tla
```

| Configuration | Result | Evidence |
| --- | --- | --- |
| `OldDeleteLoaded.cfg` | Expected FAIL, exit 12 | `IdleLoadedCanDelete` fails in the initial state: P is resident, voice work idle, both engines installed, but Delete is disabled |
| `FixedDelete.cfg` | PASS, exit 0 | 50 generated / 22 distinct states, depth 7 |
| `Fixed.cfg` | PASS, exit 0 | Existing selection/recovery model: 1014 generated / 416 distinct states |
| `FixedDownload.cfg` | PASS, exit 0 | Existing nonblocking-download model: 44 generated / 24 distinct states |

Logs are in `results-lane-d/`. The fixed delete projection checks that loaded
engines remain deletable while idle, no deleted model remains resident, delete
excludes recognition requests, and unconfirmed cleanup blocks requests. Capture
arriving during cleanup preserves the files. The old refusal is a usability
invariant failure, not a claim that the old implementation deleted live weights.

The model abstracts process-exit confirmation and filesystem link validation;
focused Bun tests cover the awaited provider stop, socket ACK ordering, capture
recheck, clear refusal reasons, external links, and the link recheck after unload.
No installed recognizer was loaded, unloaded, or deleted for this qualification.
