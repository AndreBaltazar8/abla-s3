#!/usr/bin/env bash
set -euo pipefail

test_binary=${1:?integration test binary is required}
work=$(mktemp -d /tmp/abla-s3-minio.XXXXXX)
port=19002
console_port=19003
server_pid=

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    if [[ -n $server_pid ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    case $work in
        /tmp/abla-s3-minio.*) rm -rf -- "$work" ;;
    esac
}
trap cleanup EXIT

export MINIO_ROOT_USER=test-access-key
export MINIO_ROOT_PASSWORD=test-secret-key
minio server \
    --address "127.0.0.1:$port" \
    --console-address "127.0.0.1:$console_port" \
    "$work/data" >"$work/minio.log" 2>&1 &
server_pid=$!

ready=false
for _ in $(seq 1 80); do
    if curl --silent --fail --max-time 1 \
        "http://127.0.0.1:$port/minio/health/ready" >/dev/null; then
        ready=true
        break
    fi
    sleep 0.1
done
if [[ $ready != true ]]; then
    sed -n '1,160p' "$work/minio.log" >&2
    exit 1
fi

mc alias set abla-s3-test "http://127.0.0.1:$port" \
    "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb abla-s3-test/micro-integration >/dev/null

set +e
env \
    S3_ENDPOINT_HOST=127.0.0.1 \
    S3_ENDPOINT_PORT="$port" \
    S3_BUCKET=micro-integration \
    S3_REGION=us-east-1 \
    S3_ACCESS_KEY_ID="$MINIO_ROOT_USER" \
    S3_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
    S3_PATH_STYLE=true \
    S3_USE_TLS=false \
    S3_MAX_NETWORK_RETRIES=1 \
    "$test_binary"
status=$?
set -e
if [[ $status -ne 0 ]]; then
    sed -n '1,200p' "$work/minio.log" >&2
fi
exit "$status"
