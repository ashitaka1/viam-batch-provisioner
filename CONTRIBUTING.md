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

Runs `swift test` over the root package (Swift 6, macOS 14+). The ProvisionerPXE tests bind unprivileged loopback ports.

`swift-openapi-generator` generates `ProvisionerAPI`'s types and `ProvisionerKit`'s client from `openapi/provisioner.yaml` at build time, through the `openapi.yaml` symlinks in each target's directory.

`swift run provisioner-probe` exercises ProvisionerKit against a running API (`scripts/api-service.sh start` runs it with its Bonjour advertisement): `check <base-url>` provisions, reads and removes a throwaway name and exits non-zero on any mismatch; `browse` lists advertised servers for five seconds; `watch <base-url>` prints every queue update and connection state; `notify <base-url>` prints each notification the app would post for an install that completes or fails. The `viam-*` commands call Viam with `VIAM_API_KEY_ID` and `VIAM_API_KEY` when set, otherwise with the org's key paired into the app's Keychain: `viam-locations <org-id>` lists the org's locations; `viam-batch <org-id> <location-id> <prefix> <count>` creates machines as the app does, checks each `viam.json` against Viam's part, deletes them and exits non-zero on any failure; `viam-delete-key <org-id> <key-id>` deletes an org key, which the `viam` CLI can't. To run `viam-batch` against a throwaway org without pairing, mint a key with `viam organizations api-key create --org-id <org>`, export its `Key ID` and `Key Value`, and delete the key afterwards with `viam-delete-key`.

`just app` builds, signs and registers `build/Viam Provisioner.app`. It signs with `CODESIGN_IDENTITY`, else the team Developer ID when the keychain holds it, else ad hoc; an ad-hoc build asks for the login password again after each rebuild. `just pair-app [--org-id <id>]` signs the app in to a Viam org with your `viam` CLI login; it needs the registered app and creates a real API key. `just import-env <env>` copies `config/environments/<env>.env` and its packages file into the app's environments, replacing one of the same name along with any edits made to it in the app. The app has no import of its own. The recipe runs the app's binary with `--import-environment`, so the Keychain items belong to the app; run it from a logged-in terminal, since the Keychain refuses a shell without a GUI session (`-25308`). `scripts/gen-viam-protos.sh` regenerates `Sources/ViamAPI/Generated/` from the pinned `viamrobotics/api` and `viamrobotics/goutils` commits.

`swift run provisioner-pxe --interface en0 --root netboot` serves proxy DHCP and TFTP on the default ports 67, 4011 and 69 (sudo) and prints each PXE client it answers. `--dhcp-port`, `--pxe-port` and `--tftp-port` override the ports; `--offer-to <ip>:<port>` redirects offers away from the broadcast address, for testing without privileges. It runs beside no dnsmasq: stop `just dhcp` first.

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
