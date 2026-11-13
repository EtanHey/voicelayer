-------------------------- MODULE SpeechWordSeek --------------------------
(* U5 daemon word seek, extended for the 2.4 teleprompter freeze (V3-6/V3-7): the client
   (VoiceState) and the submission identity a player's speaking frame carries.

   Utterances 1..2 arrive as user submissions (request ids 1..2). Utterance 3 is the replay of
   an ended read (tts.ts replayReadback, readback scope). Tokens are [id |-> utterance, n |-> serial]:
   every accepted start (an arrival, a seek, a replay) gets the next serial. *)
EXTENDS Naturals, FiniteSets
CONSTANTS SkipReap, SkipIdentity, SkipStopFence,
          CopyIdentity   \* replayReadback spreads the ended read's metadata, speechIdentity included (tts.ts)
VARIABLES owner, latest, serial, players, pending, restart, staleSeek, stoppedSeek,
          reqOf, ended, retired, shown, accepted, staleReplay
vars == <<owner, latest, serial, players, pending, restart, staleSeek, stoppedSeek,
          reqOf, ended, retired, shown, accepted, staleReplay>>
Token(id, n) == [id |-> id, n |-> n]
NoToken == Token(0, 0)
ReplayId == 3
Utterances == 1..ReplayId
Init == /\ owner = 0 /\ latest = 0 /\ serial = 0 /\ players = {} /\ pending = NoToken /\ restart = NoToken
        /\ staleSeek = FALSE /\ stoppedSeek = FALSE
        /\ reqOf = [u \in Utterances |-> 0] /\ ended = {} /\ retired = {}
        /\ shown = NoToken /\ accepted = NoToken /\ staleReplay = FALSE
\* A new user submission: a new utterance with its own request id. Its player is an accepted start.
Arrive == /\ latest < 2 /\ serial < 4
          /\ owner' = latest + 1 /\ latest' = latest + 1 /\ serial' = serial + 1
          /\ restart' = Token(latest + 1, serial + 1)
          /\ reqOf' = [reqOf EXCEPT ![latest + 1] = latest + 1]
          /\ accepted' = Token(latest + 1, serial + 1)
          /\ UNCHANGED <<players, pending, staleSeek, stoppedSeek, ended, retired, shown, staleReplay>>
\* An accepted seek of the live utterance (offset or word): the ack is the admission.
Seek == /\ owner # 0 /\ serial < 4
        /\ pending' = Token(owner, serial + 1) /\ serial' = serial + 1
        /\ accepted' = Token(owner, serial + 1)
        /\ UNCHANGED <<owner, latest, players, restart, staleSeek, stoppedSeek, reqOf, ended, retired, shown, staleReplay>>
Decode == /\ pending.id # 0 /\ pending' = NoToken
          /\ IF owner = 0 THEN
                /\ stoppedSeek' = SkipStopFence
                /\ restart' = IF SkipStopFence THEN pending ELSE restart
                /\ UNCHANGED staleSeek
              ELSE IF pending.id = owner \/ SkipIdentity THEN
                /\ staleSeek' = (staleSeek \/ pending.id # owner)
                /\ restart' = pending /\ UNCHANGED stoppedSeek
              ELSE UNCHANGED <<restart, staleSeek, stoppedSeek>>
          /\ UNCHANGED <<owner, latest, serial, players, reqOf, ended, retired, shown, accepted, staleReplay>>
\* The player starts and the daemon emits state(speaking) with its utterance and request id. VoiceState drops a
\* speaking frame whose request id it has retired ("retired-request", VoiceState.swift handleEvent "speaking").
Start == /\ restart.id # 0 /\ (players = {} \/ SkipReap)
         /\ players' = players \cup {restart} /\ restart' = NoToken
         /\ shown' = IF reqOf[restart.id] \in retired THEN shown ELSE restart
         /\ UNCHANGED <<owner, latest, serial, pending, staleSeek, stoppedSeek, reqOf, ended, retired, accepted, staleReplay>>
Reap == /\ players # {} /\ \E p \in players: players' = players \ {p}
        /\ UNCHANGED <<owner, latest, serial, pending, restart, staleSeek, stoppedSeek, reqOf, ended, retired, shown, accepted, staleReplay>>
\* The live utterance finishes: its player has started and nothing is pending. Completion retires its submission on
\* the client (retireSelectionRequest via the empty read_queue / playback_outcome), and its audio is retained.
Finish == /\ owner # 0 /\ pending.id = 0 /\ restart.id = 0 /\ shown.id = owner
          /\ owner' = 0 /\ ended' = ended \cup {owner}
          /\ retired' = retired \cup {reqOf[owner]}
          /\ UNCHANGED <<latest, serial, players, pending, restart, staleSeek, stoppedSeek, reqOf, shown, accepted, staleReplay>>
\* Stop: the accepted start is superseded (nothing must become visible).
Stop == /\ owner # 0 /\ owner' = 0 /\ restart' = NoToken /\ accepted' = NoToken
        /\ UNCHANGED <<latest, serial, players, pending, staleSeek, stoppedSeek, reqOf, ended, retired, shown, staleReplay>>
\* Readback replay of an ended read (seekPlayback scope "readback", idle only): a new utterance and player.
\* Fixed: a fresh presentation identity (the audio/History identity is kept separately and is not modelled).
\* CopyIdentity: the replay carries the ended read's retired request id.
Replay == /\ owner = 0 /\ pending.id = 0 /\ restart.id = 0 /\ reqOf[ReplayId] = 0 /\ serial < 4
          /\ \E u \in ended :
               /\ reqOf' = [reqOf EXCEPT ![ReplayId] = IF CopyIdentity THEN reqOf[u] ELSE ReplayId]
               /\ staleReplay' = (staleReplay \/ reqOf'[ReplayId] \in retired)
          /\ owner' = ReplayId /\ serial' = serial + 1
          /\ restart' = Token(ReplayId, serial + 1) /\ accepted' = Token(ReplayId, serial + 1)
          /\ UNCHANGED <<latest, players, pending, staleSeek, stoppedSeek, ended, retired, shown>>
Next == Arrive \/ Seek \/ Decode \/ Start \/ Reap \/ Finish \/ Stop \/ Replay
Spec == Init /\ [][Next]_vars
\* The daemon's own machinery is fair: decoder results arrive, exited players are reaped, a ready player starts.
FairSpec == Spec /\ WF_vars(Decode) /\ WF_vars(Start) /\ WF_vars(Reap)
SinglePlayer == Cardinality(players) <= 1
FreshSeek == ~staleSeek
StopWins == ~stoppedSeek
\* V3-7 (Bun RED "an ended readback seek must not reuse the retired submission identity"): a replay of an ended read
\* never carries a submission identity the client has retired.
ReplayIdentityFresh == ~staleReplay
\* V3-6/V3-7 (M4 03:28:53.509 accepted, .531 dropped retired-request): an accepted start (arrival, seek or replay)
\* that nothing supersedes eventually becomes the player the client shows.
AcceptedSeekVisible == \A u \in Utterances, n \in 1..4 :
                         accepted = Token(u, n) ~> (shown = Token(u, n) \/ accepted # Token(u, n))
=============================================================================
