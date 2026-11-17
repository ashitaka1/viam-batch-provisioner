# 31. Flash SD cards and USB sticks from the macOS app

Status: Accepted

Date: 2026-10-30

## Context

v2 replaces the PXE path. Bash scripts on the server Mac write Pi SD cards ([4. Configure Pis with cloud-init on the boot partition](0004-pi-cloud-init.md)) and USB boot sticks ([6. Bake server address and identity into USB sticks](0006-usb-identity-in-grub.md) and [7. Lay out USB sticks as one FAT32 ESP on GPT](0007-usb-layout.md)). The scripts read `queue.json` and machine files from disk and write the media with `sudo dd`, `diskutil` and `parted`. A USB-booted target installs against the server's HTTP.

## Decision

The macOS app flashes SD cards and USB sticks for queued machines. It opens the raw disk through `authopen`, which asks the user for authorization per disk, and reads machines and credentials through the REST API.

## Consequences

- Flashing works from any client Mac, not only the server.
- The root helper stays limited to PXE and TFTP.
- ProvisionerServer serves the paths USB-mode installers fetch.

## Alternatives

The record states no reason that these options were not chosen.

- Keeping the bash scripts against the REST API.
- Retiring Pi and USB provisioning.
