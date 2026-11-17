# 33. Send iOS pushes through a relay

Status: Accepted

Date: 2026-10-31

## Context

iOS suspends background SSE, so iOS alerts need APNs. APNs accepts a push only when it is signed with a key from the Apple Developer team that signs the app (the signer is Viam), and the provider also needs each device's token. Site servers run on machines the key's owner does not control, and a server has no meaningful credentials ([8. Clients create Viam machines; the server stages credentials](0008-clients-create-machines.md)).

## Decision

Servers send alerts to a push relay. The relay holds the APNs key and forwards each alert to APNs. The relay is code in this repo. Its APNs key, team ID, key ID and topic are configuration, and the app's bundle ID, team and relay URL are build settings. Each server authenticates to the relay with its own credential. A relay serves one organization, and any server Mac can run it.

## Consequences

- Viam's build points at a relay Viam runs.
- An organization that builds and signs the iOS app under its own team runs its own relay with its own key.
- The key never ships to a server that is not its owner's, and revoking one server's credential leaves the others working.
- iOS alerts depend on the relay being reachable from each site.

## Alternatives

The record states no reason that these options were not chosen.

- Holding the key on every server.
- Sending no iOS pushes.
