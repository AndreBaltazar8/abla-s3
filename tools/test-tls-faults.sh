#!/usr/bin/env bash
# usage: test-tls-faults.sh <tls-fault-test binary>
# A local certificate for the peer, and a limit for a client that would hang.
set -uo pipefail

test_binary=$(realpath "${1:?TLS fault test binary is required}")
work=$(mktemp -d /tmp/abla-s3-tls-faults.XXXXXX)
trap 'find "$work" -depth -delete' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost \
    -keyout "$work/tls.key" -out "$work/tls.crt" 2>/dev/null || exit 2
SSL_CERT_FILE="$work/tls.crt" timeout 60 "$test_binary" "$work/tls.crt" "$work/tls.key"
rc=$?
[[ $rc -eq 0 ]] && echo "TLS fault test passed" || echo "TLS fault test failed: exit $rc" >&2
exit "$rc"
