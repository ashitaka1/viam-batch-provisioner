# 44. The Mac app signs in with API keys scoped below the user's account

Date: 2026-11-04

## Status

Accepted; amended by 49, which has the app hold its own keys. #123 holds the design.

## Context

Decision 43 has the Mac app act as the `viam` CLI's user login, so it can do whatever the user's account can, in every organization the user belongs to. Two uses need less than that:

- **QA in disposable guests.** `macos-qa-vm` runs the app in a Tart guest and injects its credentials into each run. A user token there reaches all of that user's organizations, and so does every copy of the file holding it. A credential for QA should reach only a QA organization.
- **Operators.** An operator who provisions machines into one location should hold a credential that reaches that location and nothing else, not an account that sees the whole organization.

Viam API keys carry those scopes: a key can be granted on an organization, a location, or a machine. The CLI holds an API-key login (`viam login api-key --key-id … --key …`), but the token path decision 43 relies on refuses it:

```
$ viam login print-access-token
Error: Not logged in as a user. Cannot print access token. Run "viam login" to sign in with your account
```

So an API-key CLI login looks signed in to the app (#103 is about how it is labelled), and then no call to Viam can get a token.

## Decision

The Mac app signs in with Viam API keys scoped to an organization or a location, and acts with a key's permissions alone. It has no user login until its own OAuth sign-in. Decision 49 says where the keys come from and where they are kept: the app holds them itself, pasted in, in the login keychain.

The app exchanges a key for a token through `AuthService/Authenticate` and holds the token in memory only, re-authenticating when its `exp` is within a minute or once on UNAUTHENTICATED.

Each key's scope is worked out when it is added and stored with it. Viam doesn't tell a key its own grant, and an organization key in a one-location organization sees what that location's key sees (decision 49), so the operator says whether the key is an organization's or a location's. An organization key holds the one organization it lists; a location key holds the one location it lists. When a key lists several, the operator gives the ID, and the key must read it with `GetLocation`, or with `GetOrganization` and `ListLocations`.

Organization and location pickers list the stored keys' scopes. An organization key's locations come from `ListLocations`; with only location keys in an organization, its locations are theirs. An environment uses the key that covers its location, preferring a location key, and an environment no key covers reads "Not reachable with this key".

## Consequences

- A key's grant bounds what the app can do with it: an organization key reaches one organization, a location key one location.
- A QA guest supplies its keys in a file named by `VIAM_PROVISIONER_KEYS_FILE` (decision 49), so a QA run holds only keys for the QA organization.
- Viam calls take their token from a `BearerTokenProvider` (decision 43); `APIKeyTokenSource` is the app's.
