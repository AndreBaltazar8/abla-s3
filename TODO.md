# TODO

- `tools/test-transfers.sh` can fail with "FAIL TLS gateway did not start": SeaweedFS's gRPC port is the port plus
  10000 (here 42694, seen 2026-11-01), which lands in Linux's ephemeral range, so another program's connection may hold
  it. It passed on the next run. The test should pick ports outside that range or retry with another base.
