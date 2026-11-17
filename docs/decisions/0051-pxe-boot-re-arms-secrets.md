# 51. A PXE boot of a bound machine re-arms its secrets

Date: 2026-11-15

Status: Accepted

Design: [ProvisionerServer: per-machine templating and credentials (#106)](https://github.com/ashitaka1/viam-batch-provisioner/issues/106)

## Context

The server serves each machine's secrets (Viam credentials, WiFi password, Tailscale auth key) once per install attempt, at a path carrying the machine's token ([ProvisionerServer: per-machine templating and credentials (#106)](https://github.com/ashitaka1/viam-batch-provisioner/issues/106)). An install that dies without the server recording a failure leaves them spent, and the machine's retry can't fetch them. A PXE offer to a bound machine that isn't Installed starts a new attempt from Found ([Provisioning steps in the app (PXE) (#108)](https://github.com/ashitaka1/viam-batch-provisioner/issues/108)). The netboot daemon sees the offer by the MAC address bound to the machine's slot ([ProvisionerServer: binding API and boot configs (#107)](https://github.com/ashitaka1/viam-batch-provisioner/issues/107)).

## Decision

A PXE offer to a bound machine that isn't Installed re-arms its secrets: they are served once more, for the attempt that offer starts. No request to the seed path re-arms them, and an Installed machine's secrets stay spent.

## Consequences

- A PXE install that fails or stalls retries when the machine reboots, with no operator action.
- A host on the serving LAN that spoofs the MAC of a bound machine that isn't Installed can PXE boot as it, receive its token, and fetch its secrets. Re-arming extends that exposure from the first attempt to every attempt until the machine is Installed.
- A USB install has no PXE offer, so nothing re-arms its secrets. A USB machine's retry is tracked in [ProvisionerServer: observed stages for USB machines (#147)](https://github.com/ashitaka1/viam-batch-provisioner/issues/147).

## Alternatives

- Secrets that stay spent until an operator re-arms the machine from its queue row expose nothing on a retry, and every retry needs someone at the app.
- Re-arming on any new request to the seed path makes retries automatic, and lets any host that learned the URL fetch the secrets again.
