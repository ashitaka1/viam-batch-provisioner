# 9. Sign in to Viam with OAuth

Status: Accepted

Date: 2026-10-02

Amended by: [42. Register the OAuth client in the project's own Viam organization](0042-register-oauth-client-in-own-org.md)

## Context

v2 clients act on Viam as their user, as described in [8. Clients create Viam machines; the server stages credentials](0008-clients-create-machines.md). The current tooling uses an org API key that the operator mints and pastes into `site.env`.

Decision 42 amends this record: it registers the client in the project's own Viam organization.

## Decision

Clients sign in with OAuth 2.0 authorization code + PKCE through `ASWebAuthenticationSession`, as the first-party Viam mobile app does, and keep tokens in the Keychain. API-key entry remains for service accounts.

## Consequences

- Users sign in the way they already do, and the app acts with exactly their permissions.
- The app needs an OAuth client ID and redirect URI registered with Viam.

## Alternatives

None recorded.
