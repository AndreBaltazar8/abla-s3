#!/usr/bin/env bash
set -euo pipefail

test_binary=${1:?integration test binary is required}
work=$(mktemp -d /tmp/abla-s3-seaweedfs.XXXXXX)
port_base=$((20000 + ($$ % 10000)))
s3_port=$port_base
master_port=$((port_base + 1))
volume_port=$((port_base + 2))
filer_port=$((port_base + 3))
server_pid=

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    if [[ -n $server_pid ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    case $work in
        /tmp/abla-s3-seaweedfs.*) find "$work" -depth -delete ;;
    esac
}
trap cleanup EXIT

access_key=test-access-key
secret_key=test-secret-key
printf '%s\n' \
    '{"identities":[{"name":"integration","credentials":[{"accessKey":"test-access-key","secretKey":"test-secret-key"}],"actions":["Admin","Read","List","Tagging","Write"]}]}' \
    >"$work/s3.json"
mkdir -p "$work/data"

weed server \
    -dir="$work/data" \
    -ip=127.0.0.1 \
    -ip.bind=127.0.0.1 \
    -master.port="$master_port" \
    -master.port.grpc="$((master_port + 10000))" \
    -master.electionTimeout=1s \
    -master.raftBootstrap \
    -master.telemetry=false \
    -master.volumeSizeLimitMB=32 \
    -volume.port="$volume_port" \
    -volume.port.grpc="$((volume_port + 10000))" \
    -volume.max=1 \
    -filer \
    -filer.port="$filer_port" \
    -filer.port.grpc="$((filer_port + 10000))" \
    -s3 \
    -s3.ip.bind=127.0.0.1 \
    -s3.port="$s3_port" \
    -s3.port.grpc="$((s3_port + 10000))" \
    -s3.config="$work/s3.json" \
    >"$work/seaweedfs.log" 2>&1 &
server_pid=$!

ready=false
for _ in $(seq 1 300); do
    if curl --silent --max-time 1 "http://127.0.0.1:$s3_port/" >/dev/null; then
        ready=true
        break
    fi
    sleep 0.1
done
if [[ $ready != true ]]; then
    sed -n '1,200p' "$work/seaweedfs.log" >&2
    exit 1
fi

mc alias set abla-s3-test "http://127.0.0.1:$s3_port" \
    "$access_key" "$secret_key" >/dev/null
mc mb abla-s3-test/micro-integration >/dev/null

set +e
env \
    S3_ENDPOINT_HOST=127.0.0.1 \
    S3_ENDPOINT_PORT="$s3_port" \
    S3_BUCKET=micro-integration \
    S3_REGION=us-east-1 \
    S3_ACCESS_KEY_ID="$access_key" \
    S3_SECRET_ACCESS_KEY="$secret_key" \
    S3_PATH_STYLE=true \
    S3_USE_TLS=false \
    S3_MAX_NETWORK_RETRIES=1 \
    "$test_binary"
status=$?
set -e
if [[ $status -ne 0 ]]; then
    sed -n '1,240p' "$work/seaweedfs.log" >&2
fi
exit "$status"
