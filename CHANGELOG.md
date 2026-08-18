# Changelog

## 0.1.0

- Add strict S3-compatible endpoint, credential, and object-key configuration.
- Add AWS Signature Version 4 header authentication with signed payload hashes.
- Add bounded PUT, GET, HEAD, and DELETE object operations.
- Add transient retries, provider diagnostics, file-backed secrets, and
  dependency-injected transport/clock hooks.
- Verify the AWS reference signature and a real SeaweedFS S3 object lifecycle.
