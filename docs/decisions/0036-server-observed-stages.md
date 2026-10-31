# 36. Detect early failures from server-observed stages

Date: 2026-10-31

## Status

Accepted

## Context

DHCP, TFTP and ISO-download failures happen before `install-report.sh` exists on the target. The Python server catches them only with the install timeout, and only for PXE machines; a USB machine has no assignment time. The v2 server answers DHCP, serves TFTP and serves the ISO itself (decisions 13 and 30).

## Decision

The v2 server records the stages it observes for each machine: offer sent, boot files sent, ISO download started, ISO download finished. A machine that stays at one of them past its stall limit fails, with a reason naming the stage. A USB stick's GRUB entries (decision 6) fetch per-machine URLs, so the server attributes a USB machine's first request to it and starts its clock there.

## Consequences

Early failures surface in minutes with the step that stalled. The stage list and the event schema gain these stages. A USB stick that never reaches the server shows as not arrived; nothing fails it. The Python server keeps the install timeout. A single timeout starting at the first attributable request, or leaving early failures to the operator, were the alternatives.
