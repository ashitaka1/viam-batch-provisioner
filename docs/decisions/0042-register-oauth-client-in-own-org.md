# 42. Register the OAuth client in the project's own Viam organization

Date: 2026-11-03

## Status

Accepted

## Context

Decision 9 has the app sign in with OAuth 2.0 authorization code + PKCE, which needs a client ID and a redirect URI. Viam's first-party apps use clients that Viam registers for them. Any organization owner can register OAuth apps for their organization with `viam organization auth-service enable` and `viam organization auth-service oauth-app create`. The organization needs a logo and a support email before its auth service can be enabled.

## Decision

The app's client is an OAuth app registered in a Viam organization the project owns:

- redirect URI `viam-provisioner://login-callback`, the scheme the app already registers
- PKCE required, with client authentication `not_required_when_using_pkce`, so the app holds no secret
- grants `authorization_code` and `refresh_token`

## Consequences

Building and registering the app needs nothing from Viam. A fork registers its own client in its own organization and builds with that client ID.

A client registered by Viam, as its mobile app has, was the alternative. It ties a third-party app to Viam's process for every new client and redirect URI. The client Viam's MCP server hands to any caller through its registration endpoint is another; it exists for MCP clients, and its terms can change with them.
