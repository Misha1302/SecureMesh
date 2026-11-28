------------------------------ MODULE SendGate ------------------------------
EXTENDS Naturals
\* One sender, one logical message. Initial remote leaf 0 is replaced by leaf 1.
\* Directory checkpoints 0 and 1 are ordered. Checkpoint 1 revokes leaf 0.
VARIABLES head, known, highWater, epoch, fresh, quarantined, online, stable,
          pending, prepared, inFlight, delivered, handoff
vars == <<head, known, highWater, epoch, fresh, quarantined, online, stable,
          pending, prepared, inFlight, delivered, handoff>>
localTrust == <<known, highWater, epoch, fresh, quarantined>>
queue == <<pending, prepared, inFlight, delivered>>
NoLeaf == 2
InitialEvent == [leaf |-> NoLeaf, seen |-> 0, admissible |-> TRUE]
Init == /\ head = 0 /\ known = 0 /\ highWater = 0 /\ epoch = 0
        /\ fresh = FALSE /\ quarantined = FALSE /\ online = FALSE /\ stable = FALSE
        /\ pending = TRUE /\ prepared = NoLeaf /\ inFlight = FALSE
        /\ delivered = FALSE /\ handoff = InitialEvent

PublishRevocation == /\ head = 0 /\ head' = 1
                     /\ UNCHANGED <<localTrust, online, stable, queue, handoff>>

\* A successful fresh quorum response covers the full interval through head.
\* Replaying cached bytes has no transition that refreshes the clock.
Sync == /\ online /\ (~fresh \/ known # head)
        /\ known' = head /\ highWater' = head /\ fresh' = TRUE
        /\ prepared' = IF prepared = head THEN prepared ELSE NoLeaf
        /\ UNCHANGED <<head, epoch, quarantined, stable, online, pending,
                       inFlight, delivered, handoff>>

Expire == /\ ~stable /\ fresh /\ fresh' = FALSE
          /\ UNCHANGED <<head, known, highWater, epoch, quarantined, online,
                         stable, queue, handoff>>

\* Abstract authenticated MLS removal/addition or safe new join after restore.
InstallEpoch == /\ online /\ fresh /\ (quarantined \/ epoch # known)
                /\ epoch' = known /\ quarantined' = FALSE /\ prepared' = NoLeaf
                /\ UNCHANGED <<head, known, highWater, fresh, online, stable,
                               pending, inFlight, delivered, handoff>>

Prepare == /\ pending /\ fresh /\ ~quarantined /\ epoch = known
           /\ prepared # epoch /\ prepared' = epoch
           /\ UNCHANGED <<head, localTrust, online, stable, pending, inFlight,
                          delivered, handoff>>

\* This transition is the actual boundary where transport owns a copy.
\* 'handoff' and 'highWater' are observation variables, never consulted as guards.
Dispatch == /\ online /\ pending /\ prepared = epoch /\ fresh
            /\ ~quarantined /\ epoch = known
            /\ handoff' = [leaf |-> prepared, seen |-> highWater,
                            admissible |-> fresh /\ ~quarantined]
            /\ inFlight' = TRUE /\ prepared' = NoLeaf
            /\ UNCHANGED <<head, localTrust, online, stable, pending, delivered>>

\* Lost acknowledgement leaves the stable logical message pending. A previously
\* handed-off copy can arrive even after a revocation or offline interval.
Receive == /\ inFlight /\ ~delivered /\ delivered' = TRUE
           /\ UNCHANGED <<head, localTrust, online, stable, pending, prepared,
                          inFlight, handoff>>
LoseAck == /\ ~stable /\ inFlight /\ inFlight' = FALSE
           /\ UNCHANGED <<head, localTrust, online, stable, pending, prepared,
                          delivered, handoff>>
Ack == /\ online /\ delivered /\ inFlight /\ pending
       /\ pending' = FALSE /\ prepared' = NoLeaf /\ inFlight' = FALSE
       /\ UNCHANGED <<head, localTrust, online, stable, delivered, handoff>>

\* A normal restart stutters (SQLCipher commit is atomic). A detected restore
\* brings back checkpoint 0 and possibly old ciphertext. Rejoin is mandatory.
Restore == /\ ~stable /\ pending
           /\ known' = 0 /\ epoch' = 0 /\ fresh' = FALSE /\ quarantined' = TRUE
           /\ prepared' = 0
           /\ UNCHANGED <<head, highWater, online, stable, pending, inFlight,
                          delivered, handoff>>
ToggleNetwork == /\ ~stable /\ online' = ~online
                 /\ UNCHANGED <<head, localTrust, stable, queue, handoff>>

\* Liveness assumption: eventually transport and witnesses stay reachable,
\* with sufficient clock validity and no more crashes/ACK loss.
Stabilize == /\ ~stable /\ stable' = TRUE /\ online' = TRUE
             /\ UNCHANGED <<head, localTrust, queue, handoff>>
Next == PublishRevocation \/ Sync \/ Expire \/ InstallEpoch \/ Prepare \/ Dispatch
        \/ Receive \/ LoseAck \/ Ack \/ Restore \/ ToggleNetwork \/ Stabilize
Spec == Init /\ [][Next]_vars /\ WF_vars(Stabilize) /\ WF_vars(Sync)
        /\ WF_vars(InstallEpoch) /\ WF_vars(Prepare) /\ WF_vars(Dispatch)
        /\ WF_vars(Receive) /\ WF_vars(Ack)
SafeHandoff == handoff.leaf = NoLeaf \/
               (handoff.admissible /\ handoff.leaf = handoff.seen)
NoSilentRollback == quarantined \/ known = highWater
HistoryBound == known <= highWater /\ highWater <= head
QueueAcknowledged == ~pending => delivered
Progress == <>(~pending)
=============================================================================
