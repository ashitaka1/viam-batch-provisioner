# 45. The helper serves on request and keeps no configuration

Date: 2026-11-05

## Status

Accepted

The code now calls the helper the netboot daemon: `ProvisionerNetboot`, `ProvisionerNetbootCore`, `ProvisionerNetbootXPC`, `provisioner-netbootctl`, `just netboot`, and the launchd label `com.bringingfire.viam-provisioner.netboot`.

## Context

`ProvisionerHelper` runs as root from boot (decision 30) and hosts ProvisionerPXE. Its peer, `ProvisionerServer`, knows the serving interface and boot file from its settings and writes the TFTP root's per-MAC files (#107). launchd restarts either daemon on its own.

## Decision

The helper binds nothing until a peer calls `serve(interface:bootFilename:)` over XPC, and stores neither argument. Serving outlives the connection that asked for it; `stopServing` ends it. `HelperClient` calls `serve` again with its last arguments when the connection is interrupted, which is how a peer sees a helper restart. Files in the TFTP root persist on disk at `/Library/Application Support/Viam Provisioner/TFTP`.

## Consequences

The server is the one owner of where PXE is served, and the helper's state after a restart is whatever the server asks for. Between a helper restart and the server's next `serve`, PXE goes unanswered. With the server stopped, nothing serves PXE. A helper that reads a settings file of its own at launch was the alternative; it puts a second copy of the interface setting on disk for the root process to read.
