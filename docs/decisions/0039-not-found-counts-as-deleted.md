# 39. A NOT_FOUND from DeleteKey counts as deleted

Date: 2026-11-01

## Status

Accepted

## Context

Pairing an org again replaces its key, and the app deletes the old key in Viam. The old key may already be gone: an operator removed it in Viam, or an earlier delete succeeded and the Keychain update did not. `DeleteKey` for a missing key ID returns gRPC status 5 (NOT_FOUND), verified live.

## Decision

`ViamKeyDeleter` treats NOT_FOUND as success. Any other error becomes a warning naming the key left in Viam, and the replacement proceeds.

## Consequences

Replacing a key whose predecessor is already gone shows no warning. A NOT_FOUND caused by a wrong key ID rather than a deleted key is also hidden. Reporting NOT_FOUND as a failure would warn the operator about a key that no longer needs deleting.
