# 49. The Mac app holds its own Viam API keys

Date: 2026-11-06

Status: Accepted

Supersedes: [43. Sign the Mac app in to Viam through the viam CLI's login](0043-sign-in-through-the-viam-cli.md)

Amends: [44. The Mac app signs in with API keys scoped below the user's account](0044-sign-in-with-scoped-api-keys.md)

Design: [Sign in with pasted Viam API keys held in the app's Keychain (#123)](https://github.com/ashitaka1/viam-batch-provisioner/issues/123)

## Context

[43. Sign the Mac app in to Viam through the viam CLI's login](0043-sign-in-through-the-viam-cli.md) has the Mac app act as the `viam` CLI's login, and [44. The Mac app signs in with API keys scoped below the user's account](0044-sign-in-with-scoped-api-keys.md) adds the CLI's API-key login beside it. The CLI holds one login, shared with Terminal and the bash tooling. Signing the app in or out changed the CLI's login, and `provision-batch.sh` logging the CLI in broke the app's. The app's own OAuth sign-in ([42. Register the OAuth client in the project's own Viam organization](0042-register-oauth-client-in-own-org.md)) waits on [Viam sign-in with OAuth + PKCE (#60)](https://github.com/ashitaka1/viam-batch-provisioner/issues/60).

## Decision

The app keeps its own Viam API keys in the login keychain, and never runs the `viam` CLI or reads `~/.viam/`.

- The app stores any number of keys, each scoped to an organization or a location. The Keychain account is the key ID, and the item records the key's scope.
- A key gets in by pasting its ID and secret and saying whether it is an organization's or a location's. The app checks it with Viam and works out its scope before saving it. A key that fails is not stored.
- Signed in means at least one stored key. The app has no user login until its own OAuth sign-in.
- Environments name no key. The app uses a stored key whose scope covers the environment's location, preferring a location key.
- QA guests load keys from a JSON file whose path is in `VIAM_PROVISIONER_KEYS_FILE`, each entry through the paste path.

## Consequences

- The CLI and the app no longer change each other's sign-in. `provisioner-probe` may still use the CLI.
- An operator creates keys at app.viam.com or with the CLI, and pastes them in. Removing a key from the app leaves it valid at Viam.
- A key the app creates after OAuth, and any other way a key arrives, use the same storage.
- The CLI lookup, `viam login` and `print-access-token` of [43. Sign the Mac app in to Viam through the viam CLI's login](0043-sign-in-through-the-viam-cli.md) leave the app. Its `BearerTokenProvider` stays, with the API-key provider as the app's implementation.
- The key handoff of [40. Pair the app with an org API key minted by the viam CLI](0040-pair-api-keys-from-the-viam-cli.md) waits for the iPhone milestone, with iCloud Keychain sync ([Sync the app's Viam API keys through iCloud Keychain (#175)](https://github.com/ashitaka1/viam-batch-provisioner/issues/175)).

## Checks against Viam

Run on 2026-11-11 with an organization key and a location key in the QA organization, which had two locations:

| Call | Organization key | Location key |
|---|---|---|
| `ListOrganizations` | the organization | the organization |
| `GetOrganization` | the organization | the organization |
| `ListLocations` | both locations | its own location only |
| `GetLocation` | either location | its own location |

`ListOrganizationMembers`, `ListKeys` and `ListFragments` answer both keys alike. With one location in the organization, the two keys get identical answers to every call, so a key's scope can't be worked out from the key alone. The paste form asks whether the key is an organization's or a location's. A location key's location is the one it lists, and an optional ID settles a key that lists several. A wrong choice of Organization goes unnoticed until Viam refuses a call ([Rethink how the app learns an API key's scope (#193)](https://github.com/ashitaka1/viam-batch-provisioner/issues/193)).

## Alternatives

- Keeping the CLI's login, as [43. Sign the Mac app in to Viam through the viam CLI's login](0043-sign-in-through-the-viam-cli.md) and [44. The Mac app signs in with API keys scoped below the user's account](0044-sign-in-with-scoped-api-keys.md) had it, ties the app's sign-in to Terminal and the bash tooling.
