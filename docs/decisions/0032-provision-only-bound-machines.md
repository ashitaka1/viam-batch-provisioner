# 32. Provision only machines bound to a slot

Status: Accepted

Date: 2026-10-30

## Context

The watcher gives each new PXE MAC the next queued name, and any MAC without a guard boots the autoinstall. Once several clients queue batches with their own environments, an arriving MAC's batch is ambiguous, and any machine on the network that network-boots first is reinstalled unattended. The PXE server also serves people who want a stock Ubuntu install.

## Decision

In the v2 server, only a MAC bound to a queue slot is provisioned. A bound MAC boots the autoinstall for its slot. An unbound MAC gets a GRUB menu that defaults to booting from local disk after the timeout and offers the stock Ubuntu installer, run interactively with no autoinstall and no Viam setup. Every unbound PXE boot emits an `unrecognized-machine` event that includes the MAC, and a client binds that MAC to a slot from the event. The MAC's next PXE boot provisions it. Camera binding ([10. Bind hardware to names with the camera](0010-camera-binding.md)) is the other way to bind.

## Consequences

- A machine is provisioned into the batch its operator chose, and nothing is installed without a binding or a person at the console.
- Every provisioned machine takes a binding step, so batch provisioning is boot once, bind, boot again, unless the machine was bound beforehand with the camera.
- The server needs a binding API and boot configs.
- The Python watcher keeps FIFO assignment until it is retired.

## Alternatives

The record states no reason that these options were not chosen.

- FIFO assignment across batches.
- An active-batch selector.
- Binding only when batches overlap.
