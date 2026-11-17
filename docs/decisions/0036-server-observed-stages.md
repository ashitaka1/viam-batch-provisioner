# 36. Detect early failures from server-observed stages

Date: 2026-10-31

Status: Accepted

## Context

DHCP, TFTP and ISO-download failures happen before `install-report.sh` exists on the target. The Python server catches them only through the install timeout, and only for PXE machines. A USB machine has no assignment time. The v2 server answers DHCP, serves TFTP and serves the ISO itself ([13. Answer PXE natively in the v2 server](0013-native-pxe.md) and [30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)).

## Decision

The v2 server records the stages it observes for each machine: offer sent, boot files sent, ISO download started, ISO download finished. A machine that stays at one of them past its stall limit fails, with a reason naming the stage. A USB stick's GRUB entries ([6. Bake server address and identity into USB sticks](0006-usb-identity-in-grub.md)) fetch the machine's image URL and seed path, so the server attributes a USB machine's first request to it and starts its clock there.

## Consequences

- Early failures surface in minutes with the step that stalled.
- The stage list and the event schema gain these stages.
- A USB stick that never reaches the server shows as not arrived, and nothing fails it.
- The Python server keeps the install timeout.

## Alternatives

- A single timeout starting at the first attributable request. The record gives no reason it was not chosen.
- Leaving early failures to the operator. The record gives no reason it was not chosen.
