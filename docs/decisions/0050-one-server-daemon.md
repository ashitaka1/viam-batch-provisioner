# 50. Server mode is one unprivileged daemon that answers PXE itself

Date: 2026-11-14

Status: Accepted

Supersedes: [45. The helper serves on request and keeps no configuration](0045-helper-serves-on-request.md)

Amends: [13. Answer PXE natively in the v2 server](0013-native-pxe.md), [30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)

Design: [Register the server daemon from the server-mode toggle (#210)](https://github.com/ashitaka1/viam-batch-provisioner/issues/210)

## Context

[13. Answer PXE natively in the v2 server](0013-native-pxe.md) put proxy DHCP and TFTP in a privileged helper on the assumption that UDP 67, 69 and 4011 need root, and [30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md) made server mode two launch daemons: the root helper and `ProvisionerServer`. [45. The helper serves on request and keeps no configuration](0045-helper-serves-on-request.md) then had the helper serve only when the server asks over XPC. Since macOS 10.14, any user may bind a port below 1024 on `0.0.0.0`. Only a bind to a specific address still needs root.

## Decision

Server mode is one launch daemon, `ProvisionerServer`, registered with `SMAppService`, `RunAtLoad` and `KeepAlive`, running as the hidden account `_viamprovisioner`. It hosts HTTP, REST/SSE, the queue, templating, Bonjour, and `PXEServer` in its own process, with the TFTP root in its own data.

- Every PXE socket binds `0.0.0.0` restricted to the serving interface (`IP_BOUND_IF`, `SO_BINDTODEVICE` on Linux), TFTP included.
- The app creates `_viamprovisioner` and the server's directory under `/Library/Application Support/Viam Provisioner/Server` when hosting is first turned on, with one administrator authorization, and removes both on "Remove Server Data…" the same way.
- A Linux server runs as an unprivileged systemd service with `AmbientCapabilities=CAP_NET_BIND_SERVICE`.

## Consequences

- Each PXE event is seen by the process that owns the queue, as [13. Answer PXE natively in the v2 server](0013-native-pxe.md) intended. The helper, its XPC contract, its peer checks and the server's helper link go.
- Nothing in server mode runs as root after setup.
- Account creation and removal ask for an administrator's password.
- `provisioner-pxe` and the CONTRIBUTING hardware check run without sudo.

## Checks

Run on 2026-11-14 on a Mac on 192.168.7.0/24, as an ordinary user. `provisioner-pxe` on en0 bound the production ports DHCP 67, PXE 4011 and TFTP 69 once its TFTP socket bound `0.0.0.0` restricted to en0. It answered a broadcast PXE discover with a proxy offer naming itself and `grubx64.efi`, and served a 300,000-byte file over TFTP intact. Bound to the interface's own address, the TFTP socket fails with `EACCES`.

## Alternatives

- Keeping the root helper ([13. Answer PXE natively in the v2 server](0013-native-pxe.md), [30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md), [45. The helper serves on request and keeps no configuration](0045-helper-serves-on-request.md)) adds a second process, an XPC protocol and a root surface that nothing needs.
- Running the server as root removes the helper but puts network-facing parsing and templating in a root process.
