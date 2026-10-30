# Contributing

## Setup

Install the host tools in README's prerequisites, then:

```bash
just doctor                         # verify host tools
just setup-wizard                   # create config/site.env
python3 -m venv .venv
.venv/bin/pip install viam-sdk pyyaml jsonschema
```

The wizard creates `.venv` with `viam-sdk` when you choose `full` mode. PyYAML and jsonschema are needed only for the contract test.

## Test

```bash
just test
```

Runs `unittest discover` over `pxe-watcher/`, preferring `.venv/bin/python3`. Without PyYAML and jsonschema, `test_contract.py` skips.

The daemons run the watcher and API on `/usr/bin/python3` or Homebrew's, which may be 3.9. Keep `pxe-watcher/` free of 3.10-only syntax.

### Swift package

```bash
just test-swift
```

Runs `swift test` over `Sources/ProvisionerPXE` (Swift 6, macOS 13+, SwiftNIO). The tests bind unprivileged loopback ports.

`swift run provisioner-pxe --interface en0 --root http-server/tftp` serves proxy DHCP and TFTP on the default ports 67, 4011 and 69 (sudo) and prints each PXE client it answers. `--dhcp-port`, `--pxe-port` and `--tftp-port` override the ports; `--offer-to <ip>:<port>` redirects offers away from the broadcast address, for testing without privileges. It runs beside no dnsmasq: stop `just dhcp` first.

## Run pieces alone

| Command | Runs |
|---------|------|
| `just up` / `just down` | nginx container |
| `just dhcp` | dnsmasq |
| `just watch` | watcher in the foreground (sudo) |
| `just api` | API in the foreground |
| `just build-config` | Render `http-server/autoinstall/user-data` |
| `just logs` | Follow HTTP requests |

`just serve` refuses to start while the LaunchDaemons are installed; use `just daemon-status`, or `just stop-daemon` first.

## Exercise the watcher without hardware

Broadcast a forged PXE DHCPDISCOVER from an unprivileged UDP socket bound to the serving interface's IP: a BOOTP header whose `chaddr` is a made-up MAC, option 60 `PXEClient:…`, sent to `255.255.255.255:67`. The live watcher assigns the next queued name to that MAC.

## Validate on hardware

A change to the boot chain, autoinstall config, watcher or install reports is finished when a real machine has installed through it. The testbed is a Minisforum UM890 Pro on Ubuntu 24.04.
