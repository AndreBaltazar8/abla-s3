# Abla S3

A small, typed S3-compatible client written in Abla. It signs requests with
AWS Signature Version 4 and provides object upload, download, metadata,
deletion, bounded listing, and bucket creation/metadata for AWS S3-style HTTPS endpoints, including multi-GB objects in bounded
memory and presigned URLs. The real compatibility suite
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

Objects that fit in memory take one call each, up to 64 MiB:

- `putObject(key, body, contentType)`
- `getObject(key)`
- `headObject(key)`
- `deleteObject(key)`

Objects of any size go through [streaming transfers](#streaming-transfers).

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

The hosted Abla transport bounds TCP connection establishment to ten seconds.
Larger `S3_TIMEOUT_MS` values remain valid for the client's retry policy and
are clamped only at the socket-connect boundary.

## Buckets and object listings

All bucket operations address the bucket in `S3Config`, with the same signing,
path-style/virtual-host addressing, response byte limit and bounded retries as
other requests:

- `headBucket(): S3Result` checks access. `bucketRegion` retains the server's
  `x-amz-bucket-region` hint, including on errors. A bodyless 403 stays an
  error; it does not establish that the bucket is absent.
- `createBucket(locationConstraint = ""): S3Result` sends a signed PUT. An
  empty argument uses `config.regionName`; `us-east-1` and R2's `auto` send
  no configuration body. Other constraints use `CreateBucketConfiguration`
  XML. The argument does not change the configured signing region or endpoint.
  Use the intended regional endpoint for AWS; the global `s3.amazonaws.com`
  endpoint requires signing in `us-east-1` and may return a redirect for
  another location. Redirects and provider errors are returned to the caller,
  without automatically forwarding credentials or treating an already-owned
  bucket as a new success.
- `listObjects(prefix = "", delimiter = "", maxKeys = 1000,
  continuationToken = ""): S3ObjectList` fetches one ListObjectsV2 page.
  `maxKeys` is 1 through 1000. Each `S3Object` exposes `key`, `size`, `etag`,
  `lastModified` and `storageClass`. `commonPrefixes` contains delimiter groups;
  `truncated` and `nextContinuationToken` expose paging.

Listings request `encoding-type=url`. XML entities and then percent-encoded
keys/prefixes are decoded exactly once; a literal `+` remains `+`. Percent decoding is skipped
when the response omits `EncodingType=url`. Continuation
tokens remain opaque. Malformed XML, invalid sizes, invalid encodings or a
truncated page without a progressing token return `invalid_response`, with the
HTTP status, request ID and retry count retained in `result`. XML parsing uses
the existing bounded abla-xml dependency, with DTDs/external entities disabled.
No object bodies are downloaded.

For a lazy traversal, store the mutable state returned by
`objectPages(prefix, delimiter, maxKeys, maximumPages, continuationToken)` and
call `next()` until it returns null. The iterator retains its current result
and token rather than accumulating pages. A failed page is returned once
before null, so callers must check `succeeded`. Reaching `maximumPages` while
more pages remain returns `pagination_limit`, not clean exhaustion; resume
from the iterator's `continuationToken`. Each page fetch still uses the
configured network retry bound. Missing/unchanged tokens fail; longer token
cycles cannot exceed the page bound.

```abla fragment
var pages = client.objectPages(prefix = "archives/", maximumPages = 100)
var finished = false
while (!finished) {
    val page = pages.next()
    if (page == null) finished = true
    else if (!page.succeeded) {
        eprintln("${page.result.errorCode}: ${page.result.errorMessage}")
        finished = true
    } else {
        for (item in page.objects) println(item.key)
        for (prefix in page.commonPrefixes) println(prefix)
    }
}
```

The new operations are tested against a local fake S3 with synthetic/recorded
responses, including paging and errors. They have not been tested against AWS
or R2. Protocol references: [ListObjectsV2](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html),
[HeadBucket](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadBucket.html),
[CreateBucket](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CreateBucket.html)
and [R2 compatibility](https://developers.cloudflare.com/r2/api/s3/api/).

## Streaming transfers

```abla
val client = s3Client(s3ConfigFromEnvironment())
val options = S3TransferOptions(partSizeBytes = 67108864)

val uploaded = client.uploadFile("archives/big.tar", path("/data/big.tar"))
val fetched = client.downloadFile("archives/big.tar", path("/data/copy.tar"), options)
if (!uploaded.succeeded) eprintln("${uploaded.errorCode}: ${uploaded.errorMessage}")
```

| Operation | Source or target | Peak memory |
| --- | --- | --- |
| `uploadFile(key, path, contentType, options)` | a regular file | 1 MiB buffer |
| `uploadStream(key, source, contentType, options)` | `source: FnMut() -> S3Chunk` | one part, plus a chunk in hand |
| `downloadFile(key, path, options)` | a file | 256 KiB buffer |
| `downloadStream(key, sink, options)` | `sink: FnMut(string) -> bool` | 256 KiB buffer |

The table counts what a transfer holds. The process's resident size is higher,
because the runtime lets garbage grow by 64 MiB between collections; a program
that wants less can call `memorySetCollectionGrowth`. See
[Verification](#verification) for measurements.

A source returns `s3Chunk(bytes)`, `s3ChunkEnd()`, or `s3ChunkFailed()`, which
abandons the upload rather than storing a truncated object. A sink gets the bytes
in order, each exactly once, and stops the download by returning false.

`S3TransferOptions` has `partSizeBytes` (16 MiB by default, from 5 MiB to 5 GiB),
`maximumRetries` (for each part, or between bytes of progress when downloading),
`expectedSizeBytes`, and `resume`.

**Uploads** that fit in one part are a single PUT. Anything larger is a multipart
upload, sent one part at a time, whose parts are retried with the same bytes after
a connection failure or a transient status. Payloads are `UNSIGNED-PAYLOAD`:
hashing would walk every byte in Abla, and only TLS endpoints (or numeric
loopback) are accepted anyway. No checksum other than the size is verified
end to end, so compare one yourself if you need that.

A file's part size is raised if needed to fit 10,000 parts. A stream's size is
unknown, so at 16 MiB it stops at 160 GB with `too_many_parts`: pass
`expectedSizeBytes` or a larger part size. A file that changes during its upload
fails with `source_changed`.

Any failure aborts the multipart upload. If the abort fails too, the result's
`leftoverUploadId` names what's still stored, to retry with
`abortMultipartUpload`. The stored size is checked with a HEAD after completing.

A killed process can't abort anything, and neither can a create whose response
was lost after S3 acted on it. `abortIncompleteUploads(prefix, initiatedBefore)`
sweeps those up (`listMultipartUploads` shows them); on AWS, a bucket lifecycle
rule with `AbortIncompleteMultipartUpload` does the same on a schedule. A cutoff
spares any upload whose start time the server doesn't report, and SeaweedFS 3.97
reports none: there, a cutoff sweep aborts nothing, and a sweep without one aborts
uploads that are still running.

**Downloads** stream one response, and after a failure ask for only the bytes that
haven't arrived. Every response must carry the exact expected `Content-Range` and
length, and `If-Match` ends the transfer with `object_changed` if the object is
replaced midway. `downloadFile` writes to `<target>.s3part` (mode 0600), syncs
it, and renames it over the target only when complete, so a failure leaves any
existing target alone. With `resume`, the partial file survives a failure, and a
later call continues it if the object's size and ETag still match.

`S3_TIMEOUT_MS` here bounds each stall, not the transfer, however long it runs,
so a frozen connection fails and is retried. Connecting is still limited to ten
seconds. Using TLS blocks `SIGPIPE` in the calling thread, because OpenSSL's
writes to a reset socket would otherwise end the process.

### Presigned URLs

So a large file doesn't have to pass through your server:

- `presignGet(key, expiresSeconds, downloadFilename)`
- `presignPut(key, expiresSeconds)`, for a single PUT, which S3 limits to 5 GiB
- `presignUploadPart(key, uploadId, partNumber, expiresSeconds)`

For a larger direct upload, call `createMultipartUpload`, hand out a URL for each
part, collect each response's `ETag`, and finish with `completeMultipartUpload`
or `abortMultipartUpload`. Part sizes are then the uploader's to respect. URLs last
at most seven days. Whoever holds one can use it, so treat it as a credential. A
browser also needs the bucket's CORS rules to allow the request and expose `ETag`.

SeaweedFS 3.97 ignores `response-content-disposition` on a presigned GET and
completes an upload given a wrong part ETag; 4.48 does neither. Don't rely on either
check against an old server.

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
make integration                       # a 3200 MiB file; S3_TEST_FILE_MIB changes that
```

The pure suite checks AWS's published May 2013 GET-object Signature Version 4
vector, time/URI canonicalization, hostile object keys, retries, S3 errors,
bounded configuration, and file-backed credentials. The integration suite
starts an isolated SeaweedFS S3 server, creates a bucket, and verifies binary-safe
PUT, HEAD, GET, DELETE, and post-delete denial through the real HTTP protocol.

`tests/transfer_test.ab` runs the transfers against an in-memory S3 that can fail
any request in any way. `tools/test-transfers.sh` runs them against SeaweedFS, over
plain HTTP and TLS, and compares `sha256sum`s. It also drops connections mid-part,
freezes the server with `SIGSTOP`, kills a TLS gateway and a client mid-transfer,
checks that nothing is left unfinished through both the S3 API and SeaweedFS's own
directory, and uses `curl` as the client for presigned URLs. It fails if a transfer's
peak resident memory goes over twice the part size plus 120 MiB. CI runs it with a
256 MiB file.

Peak resident memory for a 3200 MiB file, 16 MiB parts, against local SeaweedFS
(a single run on one machine; `/usr/bin/time -v` agreed within 2 MiB for the file
transfers):

| Transfer | Default collector | `memorySetCollectionGrowth(4 MiB)` |
| --- | --- | --- |
| `uploadFile` | 85 MB | 27 MB |
| `downloadFile` | 71 MB | |
| `uploadStream` | 115 MB | |
| `downloadStream` | 71 MB | 10 MB |

None of this has run against AWS itself: SeaweedFS is the only server tested, and
the only one this library claims to work with. Known AWS details are handled from
its documentation (a 200 response carrying `<Error>`, whitespace ahead of a slow
result, part size limits), through the fake server only.

## Scope

Bucket administration covers creation and HEAD only; ACLs and directory-bucket
endpoint workflows are outside this API. Listing is bounded. Transfers send one
part at a time, and an upload can't be continued by a later process, only cleaned
up. Further operations need typed APIs with their own limits and compatibility
tests.

## License

MIT
