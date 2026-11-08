#!/usr/bin/env bash
# Sourced by the SeaweedFS tests: pick_port_base.
# SeaweedFS's gRPC port is each port plus 10000, so ports run from base to base+5 and from
# base+10000 to base+10005. All of them stay below Linux's ephemeral range (32768 and up), where
# another program's outgoing connection may hold one, and none may be listening already.
port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
pick_port_base() {
    local base offset port
    for offset in $(seq 0 99); do
        base=$((10000 + ($$ + offset * 97) % 12000))
        for port in $(seq "$base" $((base + 5))) $(seq $((base + 10000)) $((base + 10005))); do
            if port_listening "$port"; then continue 2; fi
        done
        echo "$base"
        return 0
    done
    return 1
}
