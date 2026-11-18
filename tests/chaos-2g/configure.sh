#!/bin/sh
set -eu
# Called only inside this project's disposable test containers, never on host NICs.
rate="$1"; rtt="$2"; loss="$3"; seed="$4"
delay=$((rtt / 2))
if tc qdisc show dev eth0 | grep -q 'htb 1:'; then tc qdisc del dev eth0 root; fi
tc qdisc add dev eth0 root handle 1: htb default 20
tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit
tc class add dev eth0 parent 1:1 classid 1:10 htb rate "${rate}kbit" ceil "${rate}kbit" burst 1600
tc class add dev eth0 parent 1:1 classid 1:20 htb rate "${rate}kbit" ceil "${rate}kbit" burst 1600
tc qdisc add dev eth0 parent 1:10 handle 10: netem limit 1000 delay "${delay}ms" loss random "${loss}%" seed "$seed"
tc qdisc add dev eth0 parent 1:20 handle 20: netem limit 1000 delay "${delay}ms" loss random "${loss}%" seed "$((seed + 1000))"
tc filter add dev eth0 protocol ip parent 1: prio 1 u32 match ip dport 5090 0xffff flowid 1:10
tc -s qdisc show dev eth0
