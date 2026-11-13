# Asynchronous guarded list delivery

This is a proposed machine, not an implementation or native acceptance. The parked
`c11/T7-list-double-marker` code is material for the next implementation, not code
this model certifies. All example text is invented: `1. Alpha`, `2. Beta`.

## The eight rulings

1. Main owns delivery state. Capture, readback and element checks run on the AX
   worker, which may answer after any delay or never. Main handles callbacks with
   a delivery id and segment step. Old ids and steps are discarded.
2. A single deadline covers all AX work, including capture and checks. Unknown
   readback switches to an unmodified remainder. At expiry main posts that
   remainder only if its final guard can pass; otherwise it refuses/stops partial.
   It never starts another AX wait or drops another marker after expiry.
3. Every post checks secure input and the captured frontmost PID in its own main
   transition. A segmented post also consumes a successful check for its current
   id/step. That check was requested after the preceding post, including for a
   fallback. No AX call lies between the final app check and the modeled post.
4. Refusal before a post retains the whole transcript. Refusal after a prefix
   returns partial with the exact logical delivered/remaining partition. No
   automatic retry occurs. History retains the original, not the stripped text.
5. If capture cannot read the target before anything is posted: **the old single
   batch through the existing guard, exactly today's route**. This is explicitly
   `batch`, not an element-checked list segment.
6. Plain text starts in `batch`: zero AX calls, one guarded post on success, or
   zero posts on refusal/quit/drain. The original keystroke plan is opaque here.
7. Quit/drain synchronously closes the delivery as posted-so-far, with exactly one
   outcome and receipt. The detached worker need not finish. Late results cannot
   reopen a closed delivery. Drain takes zero additional clock ticks.
8. Only one delivery is active. A second can start only after the first closes;
   its id changes and outstanding old work is retained. Recording, watchdog and
   quit events remain enabled during AX work. Worker fairness is never assumed.

## Transitions and proposed Swift mapping

| State | Event | Guard | Next | Effect / Swift mapping |
| --- | --- | --- | --- | --- |
| start | list plan | `ListText` | capture | `ListContinuationTyping.segments(for:)` / `ListContinuationSegment`; proposed `ListDeliveryMachine` owns id, step, deadline |
| start | plain plan | no list break | batch | existing `SynthesizedTyping.keystrokes(for:)`, no AX |
| capture | issue / worker reply | id + step match | check or batch | proposed `.captured(id, step, target?)`; replace `ListAwareTyping.Target.makeReader` and `BoundedReader.read` with async worker, never semaphore wait |
| check | issue / worker reply | successful current element check | read or finish | proposed `.elementChecked(id, step, same)`; replace synchronous `Target.isUnchanged`; main atomically guards and posts |
| read | editor handles break | pending break | read | editor nondeterministically inserts marker or plain break |
| read | editor value visible | break landed | read | arbitrary visibility lag; no editor fairness |
| read | issue / worker reply | id + step match | check | proposed `.readback(id, step, ListContinuationReading)`; `ListContinuationTyping.read` gives inserted/plain/unknown |
| check | guarded post | secure off, captured PID, fresh check | read / finish | `SynthesizedKeyEvents.postGuardedBatch`, with pure cached match closure; no AX inside `matchesCapturedTarget` |
| any AX state | hard deadline | deadline reached | finish / done | post all markers if an already completed fresh check exists; otherwise refuse/partial; no worker dependency |
| batch | guarded post | secure off, captured PID | finish / done | existing `VoiceBarApp.typeTextGuarded`, no segment-check claim |
| finish | finalize | delivery active | done | proposed async completion with `GuardedTypingResult.posted` plus one receipt |
| any active | guard refusal | guard false | done | existing `.focusChanged` before posts; proposed `.partial(delivered, remaining)` after prefix |
| any active | quit / drain | none involving worker | done | proposed `.quit` / `.updateDrain`; one completion/receipt, no worker join |
| any active | old callback | wrong id or step | unchanged | discard, including callbacks from prior delivery |
| done | second delivery | no quit or drain | start | new id, old worker can still be outstanding |
| any | recording / watchdog | always | unchanged delivery | independent main events; no delivery lock on capture |

`GuardedTypingResult` on base main has only posted/focusChanged/failed. Partial
exists in the parked branch and must be carried through completion, History and
the daemon receipt in a future implementation. The proposed machine/event names
above are design names, not claims that those Swift types already exist.
`VoiceState.usesRichHostTyping` selects today's rich-host typing route; neither
that selection nor capture/F5 mechanics changes in this task.

## Representation and bound

`Text` is an ordered sequence of unique token identities, two per segment: a
leading marker and a payload (including its break). Payload stands for arbitrary
untouched characters, fragments and retractions; none can be trimmed/reordered.
`pos` defines `remaining = SubSeq(Text, pos, Len(Text))`. `reached` is the logical
prefix at the original target: a definitely editor-supplied marker stands in for
our omitted marker. Extra editor markers are projected out, with `doubled`
recording the observed doubled break positions. A failed omission actually removes
the token from this ledger; the conservation oracle does not manufacture it back.
Whole batches are atomic unmodified keystroke plans; internal editor continuation
is abstracted as extra markers only. Editor edits other than continuation and OS
loss/reordering of posted events are outside this alphabet.

Steps advance only on a post. A check for step k can be issued only after step
k-1 posted. Worker completion and main consumption are separate transitions;
consumption, final app/secure check and post are one main transition. No assertion
claims the focused element cannot change after worker completion.
`Late` injects old/duplicate callbacks without assuming they arrive in order.
`Worker` also retains a real outstanding old request across serialized deliveries.

Clock ticks are abstract budget units, not measured milliseconds. With weak
fairness of **Main and Clock only**, every started delivery closes. At expiry
there is at most **one additional post and one finalization main transition**
(two main transitions), or one refusal transition; all waiting consumes no main
step. This is the precise bound, rather than a wall-time scheduling guarantee.
Before expiry there are at most `Segments` posts. Drain/quit closes in its own
transition, even with a silent worker. The production 250 ms budget and two-second
watchdog are parameters to validate natively, not values established by TLC.

## Properties

| Property | Oracle |
| --- | --- |
| `NoPostToChangedApp` | Every post sees captured PID and secure input off in that main step. |
| `NoSegmentWithoutFreshCheck` | Every segmented post consumes same-id/current-step successful check requested after previous post. |
| `MainNeverWaits` | Recording, watchdog and quit actions remain enabled whenever AX is outstanding. |
| `BoundedDelivery` | Every started id eventually enters closed under main/clock fairness alone, including silent-worker runs. |
| `NoLostCharacter` | Reached prefix plus remaining equals original ordered tokens; omissions require definite landed-marker evidence. |
| `OnlyDoubledMarkerWhenSlow` | Same conservation with only extra continuation markers allowed; doubled positions belong to list breaks. Refusal/partial remain possible. |
| `PlainTextUntouched` | Plain text makes zero AX calls and uses exactly one batch on successful completion. |
| `ExactlyOneOutcome` | Closed ids have one outcome and one receipt; open ids have neither; partial never becomes posted. |
| `RecordingNeverBlocked` | Starting recording remains enabled in every state. |
| `DrainBounded` | A drain transition immediately ends active delivery without waiting for AX. |

## Exact-property mutants

Each negative config declares only its named oracle. EXPECTED_FAIL means TLC
reported that exact property, not a parse error, timeout, deadlock or another
property. It does not assert that the mutation could break no other property.

| Config | Mutation and exact oracle |
| --- | --- |
| CheckAwaitPost | Check app when issuing AX, await, then post without final check → NoPostToChangedApp. |
| MainWait | Block main actions on pending worker → MainNeverWaits. |
| Stale | Accept another id/old step check → NoSegmentWithoutFreshCheck. |
| FirstUnguarded | Bypass first post guard → NoPostToChangedApp. |
| FallbackUnguarded | Bypass fallback guard → NoPostToChangedApp. |
| NoDeadline | Remove expiry; worker never responds → BoundedDelivery. |
| DropUnknown | Drop marker on unknown readback → NoLostCharacter. |
| PreBreak | Treat reading before break landed as inserted marker → NoLostCharacter. |
| TwoReceipts | Finalization emits two receipts → ExactlyOneOutcome. |
| NoQuitReceipt | Quit omits receipt → ExactlyOneOutcome. |
| PartialPosted | A stopped prefix reports posted → ExactlyOneOutcome. |
| PlainList | Plain text enters AX list path → PlainTextUntouched. |
| DrainWorker | Drain retains active delivery while worker pending → DrainBounded. |
| BlockRecording | Delivery disables recording → RecordingNeverBlocked. |
| DropSlow | Slow/unknown readback loses a marker instead of retaining it → OnlyDoubledMarkerWhenSlow. |

## Configs, evidence and limits

Async explores answering/arbitrarily delayed workers; Silent forbids all worker
answers; Plain exercises the no-list route; Serialized explores two successive
ids with old outstanding work. All use two segments (one break), two deadline
ticks, two apps and two element identities, including change-and-change-back.
This is finite exhaustive exploration, not a parameterized proof for all lengths.
All positive configs check every property. `results/run.json` records counts,
hashes and mutant coverage; normalized negative logs retain counterexamples.

Run from this checkout:

```sh
PATH=/opt/homebrew/opt/openjdk/bin:$PATH python3 -B formal/check-model.py formal/list-delivery --record
python3 -B formal/verify-receipts.py
```

No Swift, TypeScript or product source is hashed as conformance evidence. The
receipt binds this model, configs, README and runner inputs only. Real AX timing
in Electron, the readback string algorithm, real editors, macOS permissions,
physical watchdog responsiveness, process crashes and receipt transport are not
proved. `Watch` checks event availability, not a real two-second timer.
Posted key delivery after a main check is an explicit residual race: the OS may
route an event to a process that becomes frontmost before event arrival. Focus
may also change between worker element-check completion and main posting, even
within the same app. This design proves the stated fresh-check contract, **not**
that no event ever reaches a changed element. Neither limitation is solved by
hashes or an atomic model transition.

The existing CI runner inventory requires a measured `list-delivery` budget entry
before integration. CI edits are outside this brief; local receipt verification
can pass while that separate CI inventory gate is still pending.
