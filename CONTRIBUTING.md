# Contributing

## Setup

Install the host tools listed under Prerequisites in [README.md](README.md), then:

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

`just test` runs `unittest discover` over `pxe-watcher/`, preferring `.venv/bin/python3`. Without PyYAML and jsonschema, `test_contract.py` skips.

The daemons run the watcher and API on `/usr/bin/python3` or Homebrew's, which may be 3.9. Keep `pxe-watcher/` free of 3.10-only syntax.

### Swift package

```bash
just test-swift
```

`just test-swift` runs `swift test` over the root package (Swift 6, macOS 14+). The ProvisionerPXE tests bind unprivileged loopback ports.

```bash
just build-linux
```

`just build-linux` builds ProvisionerPXE and ProvisionerServer in the `swift:6.4` Linux container ([34. Keep the server portable to Linux](docs/decisions/0034-portable-server.md)), caching the build in the `viam-provisioner-linux-build` Docker volume. It needs Docker running (`colima start`). Only the build is checked; the tests use macOS interfaces.

`swift-openapi-generator` generates `ProvisionerAPI`'s types, `ProvisionerKit`'s client and `ProvisionerServer`'s server stubs from `openapi/provisioner.yaml` at build time, through the `openapi.yaml` symlinks in each target's directory. The generator drops the properties of a schema whose `oneOf` branches only list required fields, so the contract states such rules in descriptions.

`swift run provisioner-server --files <dir>` serves `<dir>` at `/` and the API under `/api/v1/` on one port, `--port` (8234 by default), bound to `--bind` (`0.0.0.0`). Its state is stored in `--data-dir`, by default `~/Library/Application Support/Viam Provisioner/Server/`; it never touches the Python server's files, and it must lie outside `--files`. `--advertise-address <host:port>` is reported as `address` in `/api/v1/status`. `--boot-image <path under --files>` names the OS image: its name feeds the provisioning steps and the server serves it per machine at `/pxe/<name>/<file>`. `--pxe-interface <name>` serves proxy DHCP and TFTP on that interface from the server's own process, without sudo, naming `--boot-file` (`grubx64.efi` by default) as the boot file; without the flag the server reads `<data-dir>/pxe.json`, `{"interface": "en0", "boot_file": "grubx64.efi"}` with `boot_file` optional, and with neither it serves no PXE. TFTP serves `<data-dir>/tftp`, which the server creates; copy the boot files into it (`cp -R netboot/. <data-dir>/tftp/`). The server advertises the API over Bonjour as `_viam-provisioner._tcp`, with TXT `api=v1`, under the host's name, so `dns-sd -B _viam-provisioner._tcp` and the app's server menu find it; on Linux it runs `avahi-publish`, from the `avahi-utils` package, and registers again 30 seconds after a failure. The server logs each request, PXE offer, file sent, attribution of PXE activity to a queued machine, journaled event, and store or journal error. On macOS the log goes to the unified log under the subsystem `com.bringingfire.viam-provisioner`, read it with `/usr/bin/log show --last 1h --predicate 'subsystem == "com.bringingfire.viam-provisioner"'` (call `log` by its path, because zsh has a builtin of the same name), and the lines also go to stderr when stderr is a terminal. On Linux the server writes to stderr, with syslog priority prefixes when it runs under systemd, so `journalctl -t provisioner-server` reads it. The log never contains the seed route's token or query strings. `/api/v1/status` reports `netboot` as `up`, or `down` while a start is failing, retried every 30 s. Point `provisioner-probe check`, `watch` or `notify` at it to exercise it; SIGTERM or Ctrl-C ends open event streams and exits.

`swift run provisioner-probe` exercises ProvisionerKit against a running API (`scripts/api-service.sh start` runs it with its Bonjour advertisement). Its subcommands are:

- `check <base-url>` provisions, reads and removes a throwaway name and exits non-zero on any mismatch.
- `browse` lists advertised servers for five seconds.
- `watch <base-url>` prints every queue update and connection state.
- `notify <base-url>` prints each notification the app would post for an install that completes or fails.
- `viam-locations <org-id>` lists the org's locations.
- `viam-batch <org-id> <location-id> <prefix> <count>` creates machines as the app does, checks each `viam.json` against Viam's part, deletes them and exits non-zero on any failure.
- `viam-delete-key <org-id> <key-id>` deletes an org key, which the `viam` CLI can't.

`viam-locations` and `viam-batch` call Viam with `VIAM_API_KEY_ID` and `VIAM_API_KEY` when set, otherwise with the `viam` CLI's login. `viam-delete-key` needs the key. To run `viam-batch` as an org key, mint a key with `viam organizations api-key create --org-id <org>`, export its `Key ID` and `Key Value`, and delete the key afterwards with `viam-delete-key`.

`just app` builds, signs and registers `build/Viam Provisioner.app`, in release unless `BUNDLE_CONFIG=debug` is set; a cold debug build takes about half as long. When nothing it builds from has changed since its last build (`Sources/`, `App/`, `openapi/`, the package manifests, `scripts/bundle-app.sh`, the signing identity and its certificate, `swift --version` and the configuration) and the bundle's signature still verifies, it opens the existing bundle; `rm build/.app-fingerprint` forces a rebuild. Builds in different checkouts and worktrees share one bundle ID; with two running, macOS delivers install notifications to only one of them, so quit the others first (`pgrep -lf ViamProvisioner` lists them). It signs with `CODESIGN_IDENTITY` from the environment, else from `config/signing.env`, else ad hoc, and prints which; an ad-hoc build asks for the login password again after each rebuild. `config/signing.env` belongs to the Mac, apart from the environments: `just set-signing-identity` lists the keychain's codesigning identities and records the one chosen there (`config/signing.env.example` shows the format). For an identity macOS doesn't trust because Apple's intermediate certificate is missing, it offers to download the intermediate from apple.com and add it to the login keychain. An Apple Development certificate from Xcode (Settings > Accounts > Manage Certificates) is enough for local builds. `just import-env <env>` copies `config/environments/<env>.env` and its packages file into the app's environments, replacing one of the same name along with any edits made to it in the app. The app has no import of its own. The recipe runs the app's binary with `--import-environment`, so the Keychain items belong to the app; run it from a logged-in terminal, since the Keychain refuses a shell without a GUI session (`-25308`). `scripts/gen-viam-protos.sh` regenerates `Sources/ViamAPI/Generated/` from the pinned `viamrobotics/api` and `viamrobotics/goutils` commits.

`swift run provisioner-pxe --interface en0 --root netboot` serves proxy DHCP and TFTP on the default ports 67, 4011 and 69, without sudo, and prints each PXE client it answers and each file a client reads, with the MAC its DHCP request named. `--dhcp-port`, `--pxe-port` and `--tftp-port` override the ports; `--offer-to <ip>:<port>` redirects offers away from the broadcast address, for testing without privileges. It runs beside no dnsmasq: stop `just dhcp` first.

### ProvisionerNetboot

`just app` also puts the `ProvisionerNetboot` launch daemon inside the bundle and builds `build/provisioner-netbootctl`. `just netboot register` registers the daemon from the app's process and opens System Settings → General → Login Items & Extensions on the server Mac's own display, where it must be allowed under Allow in the Background. An ad-hoc build can be allowed and runs. The approval remains in effect across rebuilds signed with the same team: after `just app`, `sudo launchctl kickstart -k system/com.bringingfire.viam-provisioner.netboot` runs the new binary with no prompt. Registering again doesn't restart a running daemon. A rebuild that changes the signer, from a team to ad hoc or back, leaves the daemon `enabled` but unlaunchable: launchd exits it with 78, `Could not find and/or execute program`. `just netboot unregister`, then `just netboot register` once the unregistration has cleared (30 seconds is enough), restores it; registering straight after unregistering reuses the broken item. `just netboot status` and `just netboot unregister` do the rest. The daemon runs as root and serves only when asked:

```bash
build/provisioner-netbootctl push netboot   # copy netboot/ into /Library/Application Support/Viam Provisioner/TFTP
build/provisioner-netbootctl serve en5      # serve PXE on en5 and print each offer and file sent until ^C
build/provisioner-netbootctl stop
```

Serving continues after `serve` exits. Read its log with `log stream --predicate 'subsystem == "com.bringingfire.viam-provisioner.netboot"'`. Stop dnsmasq (`just stop`) first; both bind port 67.

### Server daemon

`just app` also puts `provisioner-server` and its launch daemon inside the bundle ([50. Server mode is one unprivileged daemon that answers PXE itself](docs/decisions/0050-one-server-daemon.md)). `just server-daemon register` creates the `_viamprovisioner` account and `/Library/Application Support/Viam Provisioner/Server` after an administrator's password when they're missing, registers the daemon, and opens nothing: turn on Viam Provisioner under Background App Activity in System Settings → General → Login Items & Extensions. The daemon runs as `_viamprovisioner`, which can't open a build inside a closed home folder (mode 750, macOS's default), so copy the bundle to `/Applications` first (`sudo cp -R "build/Viam Provisioner.app" /Applications/`) and run `just server-daemon` there with `"/Applications/Viam Provisioner.app/Contents/MacOS/ViamProvisioner" --server-daemon <action>`; from `build/` the app refuses to register. `just server-daemon unregister` keeps the account and directory; `just server-daemon remove` unregisters the daemon and deletes both after an administrator's password; `just server-daemon status` reads the built app, and exits 1 when the last action failed, another account shares `_viamprovisioner`'s ID, or hosting is on and `_viamprovisioner` can't open that copy of the app. Settings → Server does the same from the app. `"/Applications/Viam Provisioner.app/Contents/MacOS/ViamProvisioner" --server-log` prints the server's last hour of log and follows new lines, and `--server-log startup-error` prints the error that stopped the daemon's latest launch, or nothing; both read the unified log as the logged-in user, which works for an administrator. Check the account with `dscl . -read /Users/_viamprovisioner` and the daemon with `ps -o user,command -ax | grep provisioner-server`. The daemon serves PXE when `/Library/Application Support/Viam Provisioner/Server/data/pxe.json` names an interface, read at start (`sudo launchctl kickstart -k system/com.bringingfire.viam-provisioner.server` after writing it), with the boot files in that directory's `tftp/`; both must be readable by `_viamprovisioner`.

### The Mac app in a QA guest

The app's GUI and the Keychain tests run in a disposable guest through `qa-vm` (ashitaka1/macos-qa-vm); the `dev-tools:macos-app-qa` skill drives the GUI. A guest needs the following, which is stored on the host:

- `~/.config/qa-vm/secrets/viam-batch-provisioner/keys.json` contains the app's Viam API keys, a JSON array of `{"key_id", "key", "organization_id" | "location_id"}` from keys granted on the QA organization or its locations. Each entry gives `organization_id` for an organization key or `location_id` for a location key, which says the key's kind; an entry with neither is reported and skipped. At launch the app adds each entry not already in the guest's Keychain through the same check as a pasted key, and lists any entry that fails in Settings → API Keys by its key ID. Any number of guests share the file and nothing comes back from a run.
- `~/.config/qa-vm/secrets/viam-batch-provisioner/environments/` contains copies of `config/environments/`, which `sync --ref` leaves out because they're gitignored. Copy them again when an environment changes.
- The public key that each environment's `SSH_PUBLIC_KEY_FILE` names, such as `~/.ssh/id_tcos_hosts.pub`, is also needed.

A session starts from the repo's warm image, which holds a finished debug build of `main`. Rebuild it when `up --warm` refuses it or a guest build takes minutes:

```bash
qa-vm warm --ref main --build 'BUNDLE_CONFIG=debug ./scripts/bundle-app.sh' ~/eng/viam-batch-provisioner
```

A session, from the main checkout, tests each branch in the same guest. `sync` deletes the injected files, so each branch injects them again:

```bash
vm=$(qa-vm up --warm viam-batch-provisioner)
qa-vm sync --ref <branch> $vm ~/eng/viam-batch-provisioner
qa-vm inject $vm ~/.config/qa-vm/secrets/viam-batch-provisioner/keys.json keys.json
qa-vm inject $vm ~/.config/qa-vm/secrets/viam-batch-provisioner/environments src/viam-batch-provisioner/config/environments
qa-vm inject $vm ~/.ssh/id_tcos_hosts.pub .ssh/id_tcos_hosts.pub
qa-vm ssh $vm 'cd ~/src/viam-batch-provisioner && BUNDLE_CONFIG=debug ./scripts/bundle-app.sh'
# … import, drive the app; then the next branch from sync …
qa-vm down $vm
```

The guest build uses the warm image's configuration; a release build there starts from nothing. The guest has no `just`: run a recipe's commands from the `justfile`. To import an environment, run the app binary with `--import-environment config/environments/<env>.env`. The app reads its keys file from `VIAM_PROVISIONER_KEYS_FILE`; pass it when opening the app: `open --env VIAM_PROVISIONER_KEYS_FILE=$HOME/keys.json "build/Viam Provisioner.app"`. A variable set with `launchctl setenv` over `qa-vm ssh` doesn't reach the app. Commands that use the Keychain unlock it first in the same `ssh` command: `security unlock-keychain -p admin ~/Library/Keychains/login.keychain-db && …`. Headless tests run in one command:

```bash
qa-vm run --ref <branch> --unlock-keychain ~/eng/viam-batch-provisioner -- 'swift test'
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

To validate the netboot daemon, fill `netboot/` with `just setup`, bring up the HTTP server (`just up`), stop dnsmasq, register and allow the netboot daemon, run `push netboot`, then run `serve <interface>` and PXE-boot the machine. It passes when `serve` prints an `offered` line for the machine's MAC, `sent` lines for `grubx64.efi`, the GRUB config, kernel and initrd carrying that MAC, and the machine boots into the installer. The netboot daemon's part ends at the initrd; the installer talks only to nginx.

To validate the server, as an ordinary user with no sudo, fill `netboot/` with `just setup`, bring up the HTTP server (`just up`), stop dnsmasq, make sure the netboot daemon is not serving, then copy `netboot/` into `<data-dir>/tftp/`, run `swift run provisioner-server --files <dir> --data-dir <data-dir> --port 8299 --pxe-interface <interface>`, and PXE-boot the machine. It passes when the server logs a `PXE offer` line for the machine's MAC and `TFTP sent` lines for `grubx64.efi`, the GRUB config, kernel and initrd carrying that MAC, `/api/v1/status` on port 8299 shows `netboot` `up`, and the machine boots into the installer.
