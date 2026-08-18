# Abla S3

A small, typed S3-compatible client written in Abla. It signs requests with
AWS Signature Version 4 and provides bounded object upload, download, metadata,
and deletion for AWS S3-style HTTPS endpoints. The real compatibility suite
currently exercises SeaweedFS; provider-specific endpoints can use the same typed
configuration without changing the signing implementation.

```abla
import github("AndreBaltazar8/abla-s3")

fun storeArchive(bytes: string): bool {
    val client = s3Client(s3ConfigFromEnvironment())
    val uploaded = client.putObject(
        "archives/report.zip", bytes, "application/zip"
    )
    uploaded.succeeded
}
```

The first release deliberately keeps the surface narrow:

- `putObject(key, body, contentType)`
- `getObject(key)`
- `headObject(key)`
- `deleteObject(key)`

Every request signs its payload hash and the required Amazon headers. Responses
are bounded, safe methods retry transient transport and service failures, and
object keys reject absolute paths, empty segments, dot traversal, control
characters, and invalid UTF-8. Plain HTTP is accepted only for the numeric
loopback test endpoint; normal clients require certificate-verified TLS.

## Configuration

`s3ConfigFromEnvironment()` reads:

| Variable | Default | Purpose |
| --- | --- | --- |
| `S3_ENDPOINT_HOST` | `s3.amazonaws.com` | Endpoint host without a scheme or path |
| `S3_ENDPOINT_PORT` | `443` | Endpoint port |
| `S3_BUCKET` | none | Bucket name |
| `S3_REGION` | `AWS_REGION` or `us-east-1` | Signing region |
| `S3_ACCESS_KEY_ID` | `AWS_ACCESS_KEY_ID` | Access key ID |
| `S3_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY` | Secret access key |
| `S3_SESSION_TOKEN` | `AWS_SESSION_TOKEN` | Optional temporary-credential token |
| `S3_PATH_STYLE` | `true` | Use `/bucket/key`; set false for bucket-host style |
| `S3_USE_TLS` | `true` | Require TLS; false is loopback-only |
| `S3_TIMEOUT_MS` | `30000` | Per-attempt timeout |
| `S3_MAX_RESPONSE_BYTES` | `33554432` | Response-body ceiling, at most 64 MiB |
| `S3_MAX_NETWORK_RETRIES` | `2` | Transient retries, from 0 through 5 |

Access keys, secret keys, and session tokens also accept the file variables
`S3_ACCESS_KEY_ID_FILE`, `S3_SECRET_ACCESS_KEY_FILE`, and
`S3_SESSION_TOKEN_FILE`. A direct value takes precedence. File inputs are
bounded and have only trailing CR/LF removed, which fits Docker/Icy secrets
without exposing credentials in arguments or source.

For virtual-hosted operation, set `S3_PATH_STYLE=false`; the client connects to
and signs `bucket.endpoint`. Custom providers commonly require path style and a
provider-specific region value.

## Results and diagnostics

Each operation returns `S3Result` with the HTTP status, response body, ETag,
version ID, provider request ID, parsed S3 error code/message, and retry count.
It never includes the configured credentials or signing key. Use the provider
request ID when diagnosing a failed request.

`s3ClientWithTransport` injects a transport, clock, and wait function for
deterministic tests. `s3SignRequest` exposes the canonical request and
string-to-sign for protocol verification, but applications should normally use
the object methods.

## Verification

```sh
make test
make integration
```

The pure suite checks AWS's published May 2013 GET-object Signature Version 4
vector, time/URI canonicalization, hostile object keys, retries, S3 errors,
bounded configuration, and file-backed credentials. The integration suite
starts an isolated SeaweedFS S3 server, creates a bucket, and verifies binary-safe
PUT, HEAD, GET, DELETE, and post-delete denial through the real HTTP protocol.

## Scope

This release intentionally does not expose bucket administration, ACLs,
presigned public URLs, multipart upload, or unbounded listing. Those can be
added as typed operations with their own limits and compatibility tests when a
real consumer needs them.

## License

MIT
