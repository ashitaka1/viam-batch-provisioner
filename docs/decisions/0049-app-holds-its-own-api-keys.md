# 49. The Mac app holds its own Viam API keys

Date: 2026-11-06

## Status

Accepted. Supersedes 43; amends 44. #123 holds the design.

## Context

Decision 43 has the Mac app act as the `viam` CLI's login, and decision 44 adds the CLI's API-key login beside it. The CLI holds one login, shared with Terminal and the bash tooling. Signing the app in or out changed the CLI's login, and `provision-batch.sh` logging the CLI in broke the app's. The app's own OAuth sign-in (decision 42) waits on #60.

## Decision

The app keeps its own Viam API keys in the login keychain, and never runs the `viam` CLI or reads `~/.viam/`.

- Any number of keys, each scoped to an organization or a location. The Keychain account is the key ID, and the item records the key's scope.
- A key gets in by pasting its ID and secret. The app checks it with Viam and works out its scope before saving it; a key that fails is not stored.
- Signed in means at least one stored key. The app has no user login until its own OAuth sign-in.
- Environments name no key. The app uses a stored key whose scope covers the environment's location, preferring a location key.
- QA guests load keys from a JSON file whose path is in `VIAM_PROVISIONER_KEYS_FILE`, each entry through the paste path.

## Consequences

- The CLI and the app no longer change each other's sign-in. `provisioner-probe` may still use the CLI.
- An operator creates keys at app.viam.com or with the CLI, and pastes them in. Removing a key from the app leaves it valid at Viam.
- A key the app creates after OAuth, and any other way a key arrives, use the same storage.
- Decision 43's CLI lookup, `viam login` and `print-access-token` leave the app. Its `BearerTokenProvider` stays, with the API-key provider as the app's implementation.

## Alternatives

Keeping the CLI's login, as decisions 43 and 44 had it, ties the app's sign-in to Terminal and the bash tooling.
