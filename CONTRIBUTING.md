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

```bash
just build-linux
```

Builds ProvisionerPXE and ProvisionerServer in the `swift:6.4` Linux container (decision 34), caching the build in the `viam-provisioner-linux-build` Docker volume. It needs Docker running (`colima start`). Only the build is checked; the tests use macOS interfaces.

`swift-openapi-generator` generates `ProvisionerAPI`'s types, `ProvisionerKit`'s client and `ProvisionerServer`'s server stubs from `openapi/provisioner.yaml` at build time, through the `openapi.yaml` symlinks in each target's directory. The generator drops the properties of a schema whose `oneOf` branches only list required fields, so the contract states such rules in descriptions.

`swift run provisioner-server --files <dir>` serves `<dir>` at `/` and the API under `/api/v1/` on one port, `--port` (8234 by default), bound to `--bind` (`0.0.0.0`). Its state lives in `--data-dir`, by default `~/Library/Application Support/Viam Provisioner/Server/`; it never touches the Python server's files, and it must lie outside `--files`. `--advertise-address <host:port>` is reported as `address` in `/api/v1/status`. Point `provisioner-probe check`, `watch` or `notify` at it to exercise it; SIGTERM or Ctrl-C ends open event streams and exits.

`swift run provisioner-probe` exercises ProvisionerKit against a running API (`scripts/api-service.sh start` runs it with its Bonjour advertisement): `check <base-url>` provisions, reads and removes a throwaway name and exits non-zero on any mismatch; `browse` lists advertised servers for five seconds; `watch <base-url>` prints every queue update and connection state; `notify <base-url>` prints each notification the app would post for an install that completes or fails. `viam-locations` and `viam-batch` call Viam with `VIAM_API_KEY_ID` and `VIAM_API_KEY` when set, otherwise with the `viam` CLI's login; `viam-delete-key` needs the key: `viam-locations <org-id>` lists the org's locations; `viam-batch <org-id> <location-id> <prefix> <count>` creates machines as the app does, checks each `viam.json` against Viam's part, deletes them and exits non-zero on any failure; `viam-delete-key <org-id> <key-id>` deletes an org key, which the `viam` CLI can't. To run `viam-batch` as an org key, mint a key with `viam organizations api-key create --org-id <org>`, export its `Key ID` and `Key Value`, and delete the key afterwards with `viam-delete-key`.

`just app` builds, signs and registers `build/Viam Provisioner.app`. It signs with `CODESIGN_IDENTITY` from the environment, else from `config/signing.env`, else ad hoc, and prints which; an ad-hoc build asks for the login password again after each rebuild. `config/signing.env` belongs to the Mac, apart from the environments: `just setup-wizard` lists the keychain's codesigning identities and records the one chosen there (`config/signing.env.example` shows the format). `just import-env <env>` copies `config/environments/<env>.env` and its packages file into the app's environments, replacing one of the same name along with any edits made to it in the app. The app has no import of its own. The recipe runs the app's binary with `--import-environment`, so the Keychain items belong to the app; run it from a logged-in terminal, since the Keychain refuses a shell without a GUI session (`-25308`). `scripts/gen-viam-protos.sh` regenerates `Sources/ViamAPI/Generated/` from the pinned `viamrobotics/api` and `viamrobotics/goutils` commits.

`swift run provisioner-pxe --interface en0 --root netboot` serves proxy DHCP and TFTP on the default ports 67, 4011 and 69 (sudo) and prints each PXE client it answers and each file a client reads, with the MAC its DHCP request named. `--dhcp-port`, `--pxe-port` and `--tftp-port` override the ports; `--offer-to <ip>:<port>` redirects offers away from the broadcast address, for testing without privileges. It runs beside no dnsmasq: stop `just dhcp` first.

### ProvisionerHelper

`just app` also puts the `ProvisionerHelper` launch daemon inside the bundle and builds `build/provisioner-helperctl`. `just helper register` registers the daemon from the app's process and opens System Settings → General → Login Items & Extensions on the server Mac's own display, where it must be allowed under Allow in the Background. An ad-hoc build can be allowed and runs. `just helper status` and `just helper unregister` do the rest. The daemon runs as root and serves only when asked:

```bash
build/provisioner-helperctl push netboot   # copy netboot/ into /Library/Application Support/Viam Provisioner/TFTP
build/provisioner-helperctl serve en5      # serve PXE on en5 and print each offer and file sent until ^C
build/provisioner-helperctl stop
```

Serving continues after `serve` exits. Its log: `log stream --predicate 'subsystem == "com.bringingfire.viam-provisioner.helper"'`. Stop dnsmasq (`just stop`) first; both bind port 67.

### The Mac app in a QA guest

The app's GUI and the Keychain tests run in a disposable guest through `qa-vm` (ashitaka1/macos-qa-vm); the `dev-tools:macos-app-qa` skill drives the GUI. What a guest needs lives on the host:

- `~/.config/qa-vm/secrets/viam/.viam`: a `viam` CLI login for the app, made once with `HOME=~/.config/qa-vm/secrets/viam viam login`. Its refresh token works once, so every run hands the refreshed login back, and only one guest uses it at a time.
- `~/.config/qa-vm/secrets/viam-batch-provisioner/environments/`: copies of `config/environments/`, which `sync --ref` leaves out because they're gitignored. Copy them again when an environment changes.
- The public key each environment's `SSH_PUBLIC_KEY_FILE` names, such as `~/.ssh/id_tcos_hosts.pub`.

A session, from the main checkout:

```bash
vm=$(qa-vm up)
qa-vm sync --ref <branch> $vm ~/eng/viam-batch-provisioner
qa-vm inject $vm ~/.config/qa-vm/secrets/viam/.viam .viam
qa-vm inject $vm ~/.config/qa-vm/secrets/viam-batch-provisioner/environments src/viam-batch-provisioner/config/environments
qa-vm inject $vm ~/.ssh/id_tcos_hosts.pub .ssh/id_tcos_hosts.pub
# … build, import, drive the app …
qa-vm collect $vm .viam ~/.config/qa-vm/secrets/viam/.viam
qa-vm down $vm
```

The guest has no `just`: run a recipe's commands from the `justfile`, such as `./scripts/bundle-app.sh` then the app binary with `--import-environment config/environments/<env>.env`. Commands that use the Keychain unlock it first in the same `ssh` command: `security unlock-keychain -p admin ~/Library/Keychains/login.keychain-db && …`. Headless tests run in one command:

```bash
qa-vm run --ref <branch> --unlock-keychain --persist ~/.config/qa-vm/secrets/viam/.viam:.viam ~/eng/viam-batch-provisioner -- 'swift test'
```

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

The helper's run: with `netboot/` filled by `just setup`, the HTTP server up (`just up`) and dnsmasq stopped, register and allow the helper, `push netboot`, then `serve <interface>` and PXE-boot the machine. It passes when `serve` prints an `offered` line for the machine's MAC, `sent` lines for `grubx64.efi`, the GRUB config, kernel and initrd carrying that MAC, and the machine boots into the installer. The helper's part ends at the initrd; the installer talks only to nginx.
