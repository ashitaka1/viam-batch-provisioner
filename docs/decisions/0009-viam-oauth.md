# 9. Sign in to Viam with OAuth

Date: 2026-10-02

## Status

Accepted

## Context

v2 clients act on Viam as their user (decision 8). The current tooling uses an org API key that the operator mints and pastes into `site.env`.

## Decision

Clients sign in with OAuth 2.0 authorization code + PKCE through `ASWebAuthenticationSession`, as the first-party Viam mobile app does, and keep tokens in the Keychain. API-key entry remains for service accounts.

## Consequences

Users sign in the way they already do, and the app acts with exactly their permissions. The app needs an OAuth client ID and redirect URI registered with Viam.
