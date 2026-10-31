# Changelog

## Unreleased

- Add streaming transfers of any size in bounded memory: `uploadFile`,
  `uploadStream`, `downloadFile`, and `downloadStream`, with multipart upload,
  retried parts, abort on failure, and downloads that resume from the last byte.
- Add the multipart operations themselves, and `listMultipartUploads` and
  `abortIncompleteUploads` for what a killed process leaves behind.
- Add presigned GET, PUT, and upload-part URLs.
- Report `contentLength` in `S3Result`.
- Spare uploads with no reported start time when `abortIncompleteUploads` has a
  cutoff. They were always aborted, including running uploads on SeaweedFS.
- Read provider error codes and messages with abla-xml, so escaped text is
  decoded. A body that isn't well-formed XML gives no provider fields, and the
  generic error code is reported instead.
- Whole-object requests over TLS set socket timeouts and survive a peer that
  resets: they could hang, or end the process with SIGPIPE.

## 0.1.0

- Add strict S3-compatible endpoint, credential, and object-key configuration.
- Add AWS Signature Version 4 header authentication with signed payload hashes.
- Add bounded PUT, GET, HEAD, and DELETE object operations.
- Add transient retries, provider diagnostics, file-backed secrets, and
  dependency-injected transport/clock hooks.
- Verify the AWS reference signature and a real SeaweedFS S3 object lifecycle.
