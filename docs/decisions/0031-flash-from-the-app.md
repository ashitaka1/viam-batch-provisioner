# 31. Flash SD cards and USB sticks from the macOS app

Date: 2026-10-30

## Status

Accepted

## Context

v2 replaces the PXE path. Pi SD cards (decision 4) and USB boot sticks (decisions 6 and 7) are written by bash scripts on the server Mac, which read `queue.json` and machine files from disk and write the media with `sudo dd`, `diskutil` and `parted`. A USB-booted target installs against the server's HTTP.

## Decision

The macOS app flashes SD cards and USB sticks for queued machines. It opens the raw disk through `authopen`, which asks the user for authorization per disk, and reads machines and credentials through the REST API.

## Consequences

Flashing works from any client Mac, not only the server. The root helper stays limited to PXE and TFTP. ProvisionerServer serves the paths USB-mode installers fetch. Keeping the bash scripts against the REST API, or retiring Pi and USB provisioning, were the alternatives.
