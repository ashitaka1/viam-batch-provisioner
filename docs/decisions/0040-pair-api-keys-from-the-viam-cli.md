# 40. Pair the app with an org API key minted by the viam CLI

Date: 2026-11-01

## Status

Accepted

## Context

Until OAuth sign-in (decision 9) has a registered client, the app needs an org API key for each Viam organization it acts in. An org API key has full write access to its org. The operator already has the `viam` CLI logged in, and that CLI can create org keys but not list or delete them. Other software running as the same macOS user can read process arguments and URLs, and can register the app's URL scheme.

## Decision

`just pair-app` uses the operator's `viam` CLI login to create a key named `provisioner-app <host> <YYYY-MM-DD>` and hands it to the app over a loopback HTTP session. The key never appears in a terminal, log, URL, QR code or clipboard.

- The command opens `viam-provisioner://pair?port=…&nonce=…` and listens on 127.0.0.1. The app commits to an ephemeral X25519 public key, then reveals it. Both sides show a four-digit code derived from both public keys, the app's nonce and the session nonce, and the operator confirms the match with `y` in the terminal.
- The key is created only after confirmation. Declining, cancelling or timing out first leaves nothing in Viam. After creation, every failure prints the key's name and where to delete it.
- The key travels sealed with a key derived from the exchange. The app stores it in the Keychain, one item per org ID, only after one AppService call with it succeeds.
- Pairing an org again replaces its key. The app deletes the replaced key in Viam with the new one (decision 39). Removing an org deletes its key from the Keychain only.
- The protocol and link format live in `ProvisionerKit`, so an iOS app can pair over the LAN from a QR code carrying host, port and nonce.

## Consequences

The operator never sees or handles a key, and a declined pairing costs nothing in Viam. The comparison code stops software that sees the pairing link or claims the URL scheme from receiving the key. Local software can still push a key for an org it controls; the sheet names the org, and nothing leaves the operator's account. Keys created before a replacement existed, and keys whose deletion fails, need deleting in Viam's web UI, since the CLI can't delete keys.

Pasting a key ID and key into the app was the alternative. It puts a full-access credential on screen and in the clipboard. A loopback handoff without the comparison code would hand the key to whichever process answered the link first. Creating the key before confirmation would leave a key in Viam for every declined pairing.
