# 45. The helper serves on request and keeps no configuration

Date: 2026-11-05

Status: Superseded

Superseded by: [50. Server mode is one unprivileged daemon that answers PXE itself](0050-one-server-daemon.md)

## Context

`ProvisionerHelper` runs as root from boot ([30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)) and hosts ProvisionerPXE. Its peer, `ProvisionerServer`, knows the serving interface and boot file from its settings and writes the boot configs in the TFTP root ([ProvisionerServer: binding API and boot configs (#107)](https://github.com/ashitaka1/viam-batch-provisioner/issues/107)). launchd restarts either daemon on its own.

The code now calls the helper the netboot daemon: `ProvisionerNetboot`, `ProvisionerNetbootCore`, `ProvisionerNetbootXPC`, `provisioner-netbootctl`, `just netboot`, and the launchd label `com.bringingfire.viam-provisioner.netboot`.

## Decision

The helper binds nothing until a peer calls `serve(interface:bootFilename:)` over XPC, and stores neither argument. Serving outlives the connection that asked for it, and `stopServing` ends it. `HelperClient` calls `serve` again with its last arguments when the connection is interrupted, which is how a peer sees a helper restart. Files in the TFTP root persist on disk at `/Library/Application Support/Viam Provisioner/TFTP`.

## Consequences

- The server is the one owner of where PXE is served, and the helper's state after a restart is whatever the server asks for.
- Between a helper restart and the server's next `serve`, PXE goes unanswered.
- With the server stopped, nothing serves PXE.

## Alternatives

- A helper that reads a settings file of its own at launch puts a second copy of the interface setting on disk for the root process to read.
