# 4. Configure Pis with cloud-init on the boot partition

Date: 2026-04-06

## Status

Accepted

## Context

Pi provisioning first used a `firstrun.sh` script. Pi OS Trixie reads cloud-init from the FAT32 boot partition, which macOS mounts without extra tools. Some setup (packages, viam-agent, Tailscale) needs the network, which isn't up when cloud-init's early stages run.

## Decision

`flash-pi-sd.sh` writes cloud-init `user-data`, `network-config` and `meta-data` to the boot partition. First boot does offline configuration; a systemd service runs the network-dependent phase.

## Consequences

The SD card is configured from the Mac with no Linux tooling. `viam.json` is moved into place with `runcmd`, because `write_files` mangles its indentation. The viam-agent unit is created in the network phase, after its binary exists.
