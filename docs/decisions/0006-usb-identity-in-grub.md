# 6. Bake server address and identity into USB sticks

Date: 2026-04-30

## Status

Accepted

## Context

PXE needs a proxy DHCP responder, and two operators running proxies on one network conflict. Some LANs' DHCP servers can't tolerate a proxy at all. A target that boots from a USB stick needs another way to find the server and learn its name, since no watcher sees it.

## Decision

Each stick's `grub.cfg` carries the host's `IP:port` and `viam_hostname=<name>` on the kernel cmdline. Credentials are staged at `/machines/by-name/<name>/viam.json` at flash time. `user-data.tpl` reads the cmdline name first and falls back to MAC lookup, so one template serves both modes. `flash-usb-batch.sh` picks the server interface once per batch (default route first, then wired) and saves the address to `config/.server-address`; `just serve-usb` reads it so the rendered `user-data` matches the sticks.

## Consequences

USB mode runs only the HTTP server and API. A stick is bound to one machine name and one server address; a host whose IP changes needs new sticks. The server learns nothing about a USB target until its installer reports.
