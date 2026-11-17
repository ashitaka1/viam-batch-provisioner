# 43. Sign the Mac app in to Viam through the viam CLI's login

Date: 2026-11-04

Status: Superseded

Superseded by: [49. The Mac app holds its own Viam API keys](0049-app-holds-its-own-api-keys.md)

Supersedes: [40. Pair the app with an org API key minted by the viam CLI](0040-pair-api-keys-from-the-viam-cli.md), for the Mac app

## Context

[40. Pair the app with an org API key minted by the viam CLI](0040-pair-api-keys-from-the-viam-cli.md) has the operator run `just pair-app` in Terminal for each org, which mints an org API key and hands it to the app. A general user shouldn't have to leave the app, or know that per-org keys exist. The `viam` CLI already holds the user's login: `viam login` signs in through the browser, and `viam login print-access-token` prints a bearer token that AppService accepts. The CLI prints that token to both stdout and stderr. An app opened from Finder gets a minimal PATH, which leaves out where Homebrew and Viam's installer put the CLI.

## Decision

The Mac app acts on Viam as the CLI's login.

- The app looks for `viam` in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and `~/bin`, then asks the user's login shell (`command -v viam`). When it finds none, it says to install the CLI and links Viam's install docs.
- Signed out, **Sign in to Viam** runs `viam login`, which opens the browser, and Cancel terminates it. The app never runs `viam login` while the CLI holds a login. Sign out runs `viam logout`, which signs the CLI out in Terminal too.
- The token comes from `print-access-token` on the child's stdout and is held in memory. It is read again when its JWT `exp` is within a minute, or once when Viam answers UNAUTHENTICATED. A refusal of the fresh token signs the app out. A failed token read contains neither stream's text.
- Any login the CLI holds counts, in its default profile, against the `base_url` in `~/.viam/cached_cli_config.json`.
- Orgs come from `ListOrganizations` with the user's token. No key is created or stored.
- Viam calls take their token from a `BearerTokenProvider`. The CLI is its first implementation, and OAuth ([42. Register the OAuth client in the project's own Viam organization](0042-register-oauth-client-in-own-org.md)) would be another.
- The pairing protocol of [40. Pair the app with an org API key minted by the viam CLI](0040-pair-api-keys-from-the-viam-cli.md) stays in `ProvisionerKit` and `ProvisionerPairHost` for an iPhone app. The Mac app ignores `viam-provisioner://pair` links and keys paired before this change.

## Consequences

- Signing in takes the browser alone.
- The app needs the CLI installed.
- The app can do whatever the user's account can, in every org it sees, not one org per key.
- Signing out of the app signs out the CLI, and signing out of the CLI signs out the app when it next reads the token.

## Alternatives

- Keeping per-org keys and moving the pairing into the app still mints a full-access key per org, and the CLI can't delete them.
- OAuth sign-in ([42. Register the OAuth client in the project's own Viam organization](0042-register-oauth-client-in-own-org.md)) needs a registered client, which waits on [Register a Viam OAuth client for the app (#28)](https://github.com/ashitaka1/viam-batch-provisioner/issues/28).
