------------------------------ MODULE Witnesses ------------------------------
EXTENDS Naturals, FiniteSets
\* Two incompatible children of one accepted parent at one tree size. One
\* designated Byzantine witness may sign both. Witness membership is fixed.
Honest == {1, 2, 3}
Witness == Honest \cup {4}
Fork == {"A", "B"}
VARIABLES recorded, signatures, accepted
vars == <<recorded, signatures, accepted>>
Init == /\ recorded = [w \in Honest |-> "parent"]
        /\ signatures = {} /\ accepted = {}
Record(w, c) == /\ recorded[w] = "parent"
                /\ recorded' = [recorded EXCEPT ![w] = c]
                /\ UNCHANGED <<signatures, accepted>>
Sign(w, c) == /\ IF w \in Honest THEN recorded[w] = c ELSE TRUE
              /\ <<w,c>> \notin signatures
              /\ signatures' = signatures \cup {<<w,c>>}
              /\ UNCHANGED <<recorded, accepted>>
Accept(c) == /\ Cardinality({w \in Witness : <<w,c>> \in signatures}) >= 3
             /\ c \notin accepted /\ accepted' = accepted \cup {c}
             /\ UNCHANGED <<recorded, signatures>>
Next == (\E w \in Honest, c \in Fork : Record(w,c))
        \/ (\E w \in Witness, c \in Fork : Sign(w,c))
        \/ (\E c \in Fork : Accept(c))
\* A witness restart between any two actions stutters: its decision is durable.
Spec == Init /\ [][Next]_vars
Consistent == Cardinality(accepted) <= 1
DurableBeforeSign == \A w \in Honest, c \in Fork :
                        <<w,c>> \in signatures => recorded[w] = c
\* Under a single proposed honest continuation, all honest witnesses are
\* reachable and scheduled fairly; the fourth witness need not cooperate.
HonestNext == (\E w \in Honest : Record(w,"A"))
              \/ (\E w \in Witness, c \in Fork : Sign(w,c))
              \/ (\E c \in Fork : Accept(c))
AvailableSpec == Init /\ [][HonestNext]_vars
                 /\ (\A w \in Honest : WF_vars(Record(w,"A")) /\ WF_vars(Sign(w,"A")))
                 /\ WF_vars(Accept("A"))
HonestProgress == <>("A" \in accepted)
=============================================================================
