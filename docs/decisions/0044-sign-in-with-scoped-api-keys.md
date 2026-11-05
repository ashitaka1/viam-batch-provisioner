# 44. The Mac app signs in with API keys scoped below the user's account

Date: 2026-11-04

## Status

Accepted. The design is open in #123.

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

The Mac app signs in with a Viam API key, alongside the CLI's user login, and acts with that key's permissions alone.

How the app takes the key, where it keeps it, how it authenticates Viam calls with it, and what it shows when the key can't list organizations or reach a location are left to the design.

## Consequences

- The key's grant bounds what the app can do: an organization key reaches one organization, a location key one location.
- A QA guest must be able to supply the key without the sign-in UI, for example from a file or the environment, so `macos-qa-vm` can start the app signed in.
- Until this lands, the app signs in only as a user, and a QA run of it holds a token for every organization that user belongs to.
- Viam calls already take their token from a `BearerTokenProvider` (decision 43); an API key is a credential the provider abstraction has to accommodate.
