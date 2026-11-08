#!/usr/bin/env bash
# Moves a large file through a real, isolated SeaweedFS with the streaming API.
# usage: test-transfers.sh <transfer-tool binary> [size in MiB, default 3200]
#
# Peak memory is the kernel's high-water mark for the client process (VmHWM,
# what /usr/bin/time -v reports as maximum resident size). Bytes are compared
# with sha256sum over the original file and what came back.
set -uo pipefail

tool=$(realpath "${1:?transfer tool binary is required}")
size_mib=${2:-3200}
if [[ $size_mib -lt 128 ]]; then
    echo "the failure tests need a file of at least 128 MiB" >&2
    exit 2
fi
part_bytes=${S3_TEST_PART_BYTES:-16777216}
# What the client may use above one part: the collector's default 64 MiB of
# growth, buffers, and the program itself.
peak_limit_kib=$(((part_bytes / 1024) * 2 + 120 * 1024))
work=$(mktemp -d /tmp/abla-s3-transfers.XXXXXX)
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
port_base=$(pick_port_base) || { echo "no free port range for SeaweedFS" >&2; exit 2; }
s3_port=$port_base
master_port=$((port_base + 1))
volume_port=$((port_base + 2))
filer_port=$((port_base + 3))
tls_port=$((port_base + 4))
server_pid=
gateway_pid=
failures=0

cleanup() {
    [[ -n $gateway_pid ]] && kill -9 "$gateway_pid" 2>/dev/null
    if [[ -n $server_pid ]]; then
        kill -CONT "$server_pid" 2>/dev/null
        kill "$server_pid" 2>/dev/null
        wait "$server_pid" 2>/dev/null
    fi
    case $work in
        /tmp/abla-s3-transfers.*) find "$work" -depth -delete ;;
    esac
}
trap cleanup EXIT

check() { # label, command...
    local label=$1
    shift
    if "$@"; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        failures=$((failures + 1))
    fi
}
same_sha() { [[ $(sha256sum <"$1" | cut -d' ' -f1) == "$2" ]]; }
equals() { [[ $1 == "$2" ]]; }
wait_for_port() {
    for _ in $(seq 1 900); do
        (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
# Set GNU_TIME to /usr/bin/time's path for a second measurement of the big file.
timed() { # output file, command...
    local output=$1
    shift
    if [[ -n ${GNU_TIME:-} ]]; then
        "$GNU_TIME" -v -o "$output" "$@"
    else
        : >"$output"
        "$@"
    fi
}
report_time() {
    grep -E 'Maximum resident|Elapsed' "$1" | sed 's/^[[:space:]]*/     time -v: /'
}
peak_of() { sed -n 's/^peak VmHWM:[[:space:]]*\([0-9]*\) kB$/\1/p' "$1" | tail -1; }
report_peak() { # label, log
    local peak
    peak=$(peak_of "$2")
    echo "     $1: peak ${peak:-?} KiB (limit $peak_limit_kib KiB), $3 s"
    check "$1 stays bounded" test "${peak:-999999999}" -le "$peak_limit_kib"
}
retries_of() { sed -n 's/.* retries=\([0-9]*\) .*/\1/p' "$1" | tail -1; }

printf '%s\n' \
    '{"identities":[{"name":"integration","credentials":[{"accessKey":"test-access-key","secretKey":"test-secret-key"}],"actions":["Admin","Read","List","Tagging","Write"]}]}' \
    >"$work/s3.json"
mkdir -p "$work/data"
weed server -dir="$work/data" -ip=127.0.0.1 -ip.bind=127.0.0.1 \
    -master.port="$master_port" -master.port.grpc="$((master_port + 10000))" \
    -master.electionTimeout=1s -master.raftBootstrap -master.telemetry=false \
    -master.volumeSizeLimitMB=512 \
    -volume.port="$volume_port" -volume.port.grpc="$((volume_port + 10000))" \
    -volume.max=64 \
    -filer -filer.port="$filer_port" -filer.port.grpc="$((filer_port + 10000))" \
    -s3 -s3.ip.bind=127.0.0.1 -s3.port="$s3_port" \
    -s3.port.grpc="$((s3_port + 10000))" -s3.config="$work/s3.json" \
    >"$work/seaweedfs.log" 2>&1 &
server_pid=$!
if ! wait_for_port "$s3_port"; then
    sed -n '1,200p' "$work/seaweedfs.log" >&2
    exit 1
fi
printf 's3.bucket.create -name micro-transfers\n' |
    weed shell -master="127.0.0.1:$master_port" >/dev/null

export S3_ENDPOINT_HOST=127.0.0.1 S3_ENDPOINT_PORT=$s3_port \
    S3_BUCKET=micro-transfers S3_REGION=us-east-1 \
    S3_ACCESS_KEY_ID=test-access-key S3_SECRET_ACCESS_KEY=test-secret-key \
    S3_PATH_STYLE=true S3_USE_TLS=false S3_MAX_NETWORK_RETRIES=2 \
    S3_TIMEOUT_MS=30000 TOOL_PART_BYTES=$part_bytes

# SeaweedFS keeps unfinished parts under this directory. Reading it is a second
# opinion on the protocol's own listing.
uploads_on_disk() {
    printf 'fs.ls /buckets/micro-transfers/.uploads\n' |
        weed shell -master="127.0.0.1:$master_port" 2>/dev/null |
        grep -cE '^[0-9a-zA-Z_-]+$'
}
no_incomplete() { # key
    [[ $("$tool" incomplete "$1" 2>/dev/null) == 0 && $(uploads_on_disk) == 0 ]]
}

echo "== generating ${size_mib} MiB"
big=$work/big.bin
dd if=/dev/urandom of="$big" bs=1M count="$size_mib" status=none
big_sha=$(sha256sum <"$big" | cut -d' ' -f1)
big_size=$(stat -c %s "$big")
echo "     size $big_size sha256 $big_sha"

# SeaweedFS splits a single PUT into chunks from 4 MiB up, and then refuses
# If-Match with the object's own ETag.
echo "== single PUTs around the chunk size"
for mib in 1 4 5 8 9 16; do
    head -c $((mib * 1048576)) "$big" >"$work/small.bin"
    small_sha=$(sha256sum <"$work/small.bin" | cut -d' ' -f1)
    "$tool" upload-file "small/$mib.bin" "$work/small.bin" 2>"$work/log"
    check "$mib MiB uploads in one PUT" grep -q 'ok=true .*parts=1 ' "$work/log"
    "$tool" download-stream "small/$mib.bin" 2>"$work/log" >"$work/small-back.bin"
    check "$mib MiB download-stream succeeds" grep -q 'ok=true' "$work/log"
    check "$mib MiB stream has the same sha256" same_sha "$work/small-back.bin" "$small_sha"
    "$tool" download-file "small/$mib.bin" "$work/small-back.bin" 2>"$work/log"
    check "$mib MiB download-file has the same sha256" same_sha "$work/small-back.bin" "$small_sha"
    "$tool" delete "small/$mib.bin" 2>/dev/null
done
find "$work/small.bin" "$work/small-back.bin" -delete

echo "== upload and download a file"
start=$SECONDS
timed "$work/time" "$tool" upload-file big/file.bin "$big" 2>"$work/log"
rc=$?
report_time "$work/time"
check "file upload succeeds" test "$rc" -eq 0
cat "$work/log" >&2
report_peak "file upload" "$work/log" $((SECONDS - start))
check "stored size matches" equals "$("$tool" size big/file.bin 2>/dev/null)" "$big_size"
check "no incomplete upload after success" no_incomplete big/
start=$SECONDS
timed "$work/time" "$tool" download-file big/file.bin "$work/back.bin" 2>"$work/log"
rc=$?
report_time "$work/time"
check "file download succeeds" test "$rc" -eq 0
cat "$work/log" >&2
report_peak "file download" "$work/log" $((SECONDS - start))
check "downloaded file has the same sha256" same_sha "$work/back.bin" "$big_sha"
check "no partial file is left" test ! -e "$work/back.bin.s3part"
find "$work/back.bin" -delete

echo "== the same with a smaller collection threshold, for comparison"
TOOL_COLLECTION_GROWTH=4194304 "$tool" download-stream big/file.bin 2>"$work/log" >/dev/null
echo "     download, 4 MiB growth: peak $(peak_of "$work/log") KiB"
TOOL_COLLECTION_GROWTH=4194304 "$tool" upload-file big/tuned.bin "$big" 2>"$work/log"
echo "     upload, 4 MiB growth: peak $(peak_of "$work/log") KiB"
"$tool" delete big/tuned.bin

echo "== stream through pipes, size unknown to the client"
start=$SECONDS
"$tool" upload-stream big/stream.bin <"$big" 2>"$work/log"
rc=$?
check "stream upload succeeds" test "$rc" -eq 0
cat "$work/log" >&2
report_peak "stream upload" "$work/log" $((SECONDS - start))
start=$SECONDS
actual=$("$tool" download-stream big/stream.bin 2>"$work/log" | sha256sum | cut -d' ' -f1)
cat "$work/log" >&2
check "streamed download has the same sha256" equals "$actual" "$big_sha"
report_peak "stream download" "$work/log" $((SECONDS - start))
"$tool" delete big/stream.bin

echo "== failures on real connections"
# Connections are dropped partway through a part, then the part is retried.
medium=$work/medium.bin
head -c 134217728 "$big" >"$medium"
medium_sha=$(sha256sum <"$medium" | cut -d' ' -f1)
TOOL_FAULT_BUDGET=8388608 TOOL_FAULT_CONNECTIONS=2 \
    "$tool" upload-file faults/retry.bin "$medium" 2>"$work/log"
check "upload survives dropped connections" test $? -eq 0
cat "$work/log" >&2
check "the retries really happened" test "$(retries_of "$work/log")" -ge 2
actual=$("$tool" download-stream faults/retry.bin 2>/dev/null | sha256sum | cut -d' ' -f1)
check "retried upload has the same sha256" equals "$actual" "$medium_sha"
check "no incomplete upload after retries" no_incomplete faults/

# After three parts are stored, nothing more gets through: the upload is abandoned.
TOOL_FAULT_TOTAL=$((part_bytes * 3 + part_bytes / 2)) TOOL_RETRIES=1 \
    "$tool" upload-file faults/doomed.bin "$medium" 2>"$work/log"
check "doomed upload reports failure" test $? -eq 3
cat "$work/log" >&2
check "doomed upload leaves nothing to clean" no_incomplete faults/
check "doomed upload stores no object" test "$("$tool" size faults/doomed.bin 2>/dev/null)" != 134217728

# The source itself fails after three parts' worth.
TOOL_SOURCE_FAIL_AT=$((part_bytes * 3 + 1)) \
    "$tool" upload-stream faults/source.bin <"$medium" 2>"$work/log"
check "failing source reports failure" test $? -eq 3
cat "$work/log" >&2
check "failing source leaves nothing to clean" no_incomplete faults/
check "failing source stores no object" test "$("$tool" size faults/source.bin 2>/dev/null)" != 134217728

# The server freezes mid-download; the socket timeout notices, and the download
# carries on from the last byte once the server is back. The sink is slowed so
# the freeze lands in the middle at any file size.
(sleep 0.5; kill -STOP "$server_pid"; sleep 3; kill -CONT "$server_pid") &
actual=$(S3_TIMEOUT_MS=1000 TOOL_RETRIES=20 TOOL_SINK_DELAY_MS=5 \
    "$tool" download-stream faults/retry.bin 2>"$work/log" | sha256sum | cut -d' ' -f1)
wait $!
cat "$work/log" >&2
check "download survives a frozen server" equals "$actual" "$medium_sha"
check "the frozen download really retried" test "$(retries_of "$work/log")" -ge 1

# The same during an upload: the source feeds two and a half parts, the server
# freezes, and the next part is written into a server that doesn't read it. One
# attempt can span about three timeouts (a partial write, a refused write, then the
# wait for a response), so the freeze must outlast those for a retry to be certain.
{
    head -c "$((part_bytes * 5 / 2))" "$medium"
    sleep 0.5
    kill -STOP "$server_pid"
    (sleep 6; kill -CONT "$server_pid") &
    tail -c "+$((part_bytes * 5 / 2 + 1))" "$medium"
    wait
} | S3_TIMEOUT_MS=1000 TOOL_RETRIES=20 "$tool" upload-stream faults/frozen.bin 2>"$work/log"
check "upload survives a frozen server" test "${PIPESTATUS[1]}" -eq 0
cat "$work/log" >&2
check "the frozen upload really retried" test "$(retries_of "$work/log")" -ge 1
actual=$("$tool" download-stream faults/frozen.bin 2>/dev/null | sha256sum | cut -d' ' -f1)
check "frozen upload has the same sha256" equals "$actual" "$medium_sha"
check "no incomplete upload after the freeze" no_incomplete faults/
"$tool" delete faults/frozen.bin

# Dropped download connections resume instead of starting again.
TOOL_FAULT_BUDGET=8388608 TOOL_FAULT_CONNECTIONS=3 \
    "$tool" download-file faults/retry.bin "$work/resumed.bin" 2>"$work/log"
check "download survives dropped connections" test $? -eq 0
cat "$work/log" >&2
check "the download really resumed" test "$(retries_of "$work/log")" -ge 3
check "resumed download has the same sha256" same_sha "$work/resumed.bin" "$medium_sha"
find "$work/resumed.bin" -delete

# A download that gives up keeps its bytes, and a later process continues them.
TOOL_FAULT_TOTAL=33554432 TOOL_RETRIES=1 TOOL_RESUME=true \
    "$tool" download-file faults/retry.bin "$work/later.bin" 2>"$work/log"
check "interrupted download reports failure" test $? -eq 3
cat "$work/log" >&2
check "interrupted download never shows the target" test ! -e "$work/later.bin"
kept=$(stat -c %s "$work/later.bin.s3part")
check "interrupted download kept its bytes" test "$kept" -ge 33000000
TOOL_RESUME=true "$tool" download-file faults/retry.bin "$work/later.bin" 2>"$work/log"
check "a later process finishes the download" test $? -eq 0
cat "$work/log" >&2
check "the later process only fetched the rest" equals \
    "$(sed -n 's/.* resumed_from=\([0-9]*\) .*/\1/p' "$work/log" | tail -1)" "$kept"
check "continued download has the same sha256" same_sha "$work/later.bin" "$medium_sha"
check "continuing removes the partial file" test ! -e "$work/later.bin.s3part"
find "$work/later.bin" -delete

# A sweep with a cutoff must not touch an upload that may still be running, even
# when the server doesn't say when it started.
running_id=$("$tool" start faults/running.bin 2>/dev/null)
check "a sweep with a cutoff spares a running upload" equals \
    "$("$tool" sweep faults/ 2000-01-01T00:00:00Z 2>/dev/null)" 0
check "the running upload is still there" equals \
    "$("$tool" incomplete faults/running.bin 2>/dev/null)" 1
"$tool" abort faults/running.bin "$running_id" 2>/dev/null

# A client killed outright can't abort; the sweep is how that gets cleaned up.
"$tool" upload-file faults/killed.bin "$medium" 2>/dev/null &
victim=$!
for _ in $(seq 1 200); do
    [[ $("$tool" incomplete faults/killed.bin 2>/dev/null) != 0 ]] && break
    sleep 0.02
done
kill -9 "$victim" 2>/dev/null
wait "$victim" 2>/dev/null
check "a killed client does leave an upload" test "$("$tool" incomplete faults/killed.bin 2>/dev/null)" -ge 1
check "the sweep aborts it" test "$("$tool" sweep faults/ 2>/dev/null)" -ge 1
check "nothing is left after the sweep" no_incomplete faults/
"$tool" delete faults/retry.bin

echo "== presigned URLs, with curl as the other client"
head -c 1048576 "$big" >"$work/small.bin"
small_sha=$(sha256sum <"$work/small.bin" | cut -d' ' -f1)
url=$("$tool" presign-put presigned/one.bin 300 2>/dev/null)
check "presigned PUT works" curl -fsS -o /dev/null -T "$work/small.bin" "$url"
url=$("$tool" presign-get presigned/one.bin 300 2>/dev/null)
check "presigned GET has the same sha256" equals \
    "$(curl -fsS "$url" | sha256sum | cut -d' ' -f1)" "$small_sha"
check "an altered presigned URL is refused" equals \
    "$(curl -s -o /dev/null -w '%{http_code}' "${url/presigned%2Fone/presigned/one}x")" 403
url=$("$tool" presign-get presigned/one.bin 1 2>/dev/null)
sleep 2
check "an expired presigned URL is refused" equals \
    "$(curl -s -o /dev/null -w '%{http_code}' "$url")" 403
# The way a browser would send a large file without passing through our server.
head -c 25165824 "$big" >"$work/direct.bin"
direct_sha=$(sha256sum <"$work/direct.bin" | cut -d' ' -f1)
split -b 15728640 "$work/direct.bin" "$work/direct.part."
upload_id=$("$tool" start presigned/direct.bin 2>/dev/null)
etags=()
number=1
for part in "$work"/direct.part.*; do
    url=$("$tool" presign-part presigned/direct.bin "$upload_id" "$number" 2>/dev/null)
    etags+=("$(curl -fsS -o /dev/null -D - -T "$part" "$url" |
        tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p')")
    number=$((number + 1))
done
"$tool" complete presigned/direct.bin "$upload_id" "${etags[@]}" 2>/dev/null
check "presigned parts complete" test $? -eq 0
check "presigned parts have the same sha256" equals \
    "$("$tool" download-stream presigned/direct.bin 2>/dev/null | sha256sum | cut -d' ' -f1)" "$direct_sha"
check "no incomplete upload after presigned parts" no_incomplete presigned/
"$tool" delete presigned/one.bin
"$tool" delete presigned/direct.bin

echo "== TLS, with certificate verification"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost \
    -keyout "$work/tls.key" -out "$work/tls.crt" 2>/dev/null
# Newer versions also start catalog listeners on fixed ports, which the server
# above already holds. Older versions don't know these flags.
gateway_flags=()
gateway_help=$(weed s3 -h 2>&1)
for flag in port.iceberg port.lance; do
    if [[ $gateway_help == *"-$flag "* ]]; then
        gateway_flags+=("-$flag=0")
    fi
done
weed s3 "${gateway_flags[@]}" -filer="127.0.0.1:$filer_port" -ip.bind=127.0.0.1 \
    -port="$((tls_port + 1))" -port.https="$tls_port" \
    -port.grpc="$((tls_port + 10000))" \
    -cert.file="$work/tls.crt" -key.file="$work/tls.key" \
    -config="$work/s3.json" >"$work/gateway.log" 2>&1 &
gateway_pid=$!
if wait_for_port "$tls_port"; then
    tls_env=(env S3_ENDPOINT_HOST=localhost S3_ENDPOINT_PORT="$tls_port"
        S3_USE_TLS=true SSL_CERT_FILE="$work/tls.crt")
    start=$SECONDS
    "${tls_env[@]}" "$tool" upload-file tls/medium.bin "$medium" 2>"$work/log"
    check "TLS upload succeeds" test $? -eq 0
    cat "$work/log" >&2
    report_peak "TLS upload" "$work/log" $((SECONDS - start))
    start=$SECONDS
    "${tls_env[@]}" "$tool" download-file tls/medium.bin "$work/tls-back.bin" 2>"$work/log"
    check "TLS download succeeds" test $? -eq 0
    cat "$work/log" >&2
    report_peak "TLS download" "$work/log" $((SECONDS - start))
    check "TLS download has the same sha256" same_sha "$work/tls-back.bin" "$medium_sha"
    find "$work/tls-back.bin" -delete
    # Without the certificate in the trust store the connection must fail.
    env S3_ENDPOINT_HOST=localhost S3_ENDPOINT_PORT="$tls_port" S3_USE_TLS=true \
        SSL_CERT_FILE=/dev/null S3_MAX_NETWORK_RETRIES=0 \
        "$tool" size tls/medium.bin >/dev/null 2>&1
    check "an untrusted certificate is refused" test $? -eq 3
    # The gateway dies mid-upload. OpenSSL then writes to a reset socket, which
    # would end the process by SIGPIPE (status 141) if it weren't blocked.
    "${tls_env[@]}" TOOL_RETRIES=1 "$tool" upload-file tls/dying.bin "$big" 2>"$work/log" &
    victim=$!
    sleep 0.5
    kill -9 "$gateway_pid"
    wait "$gateway_pid" 2>/dev/null
    gateway_pid=
    wait "$victim"
    rc=$?
    cat "$work/log" >&2
    check "a dying TLS server is a reported failure, not a signal" test "$rc" -eq 3
    # The abort couldn't get through either, so the result names what's left.
    check "the failure names the upload it couldn't abort" grep -q 'leftover=[^ ]' "$work/log"
    "$tool" sweep tls/ >/dev/null 2>&1
    check "the sweep cleans up after the dead server" no_incomplete tls/
    "$tool" delete tls/medium.bin
    "$tool" delete big/file.bin
else
    echo "FAIL TLS gateway did not start"
    sed -n '1,60p' "$work/gateway.log" >&2
    failures=$((failures + 1))
fi

echo "== $failures failure(s)"
if [[ $failures -ne 0 ]]; then
    sed -n '1,60p' "$work/seaweedfs.log" >&2
    exit 1
fi
