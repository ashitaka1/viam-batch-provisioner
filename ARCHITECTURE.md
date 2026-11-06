# Architecture

## Overview

A macOS host provisions x86 machines over the network and Raspberry Pis from SD cards. The host runs four services: dnsmasq (proxy DHCP + TFTP), nginx in Docker (HTTP), a root watcher that binds PXE clients to queued machine names, and an operator-owned REST + SSE API. Bash scripts behind `just` recipes create the queue, stage credentials and flash media. Python under `pxe-watcher/` owns all shared state.

### Boot chains

**x86 PXE.** UEFI PXE ROM → dnsmasq (proxy DHCP + TFTP) → GRUB → Ubuntu HWE kernel + initrd over TFTP → installer downloads the ISO over HTTP → autoinstall → late-commands fetch hostname and credentials by MAC → first boot with viam-agent, and Tailscale when the server has a key.

**x86 USB stick.** UEFI USB boot → GRUB on the stick → HWE kernel + initrd from the stick → installer downloads the ISO from the `IP:port` in the stick's `grub.cfg` → autoinstall → late-commands read `viam_hostname=` from `/proc/cmdline` and fetch credentials from `/machines/by-name/<name>/` → first boot. Only the HTTP server and API run.

**Raspberry Pi.** `flash-pi-sd.sh` writes the OS image, mounts the FAT32 boot partition and writes cloud-init `user-data`, `network-config` and `meta-data`. First boot configures the OS offline, then a systemd service does the network-dependent setup (packages, viam-agent, Tailscale).

## Codemap

| Path | Role |
|------|------|
| `justfile` | Operator commands; every workflow starts here |
| `netboot/dnsmasq.conf` | Proxy DHCP + TFTP config; carries no `dhcp-range` |
| `netboot/grub/grub.cfg` | Network GRUB menu; sources `provisioned/<MAC>.cfg` guards |
| `templates/user-data.tpl` | PXE and USB autoinstall config; late-commands and `error-commands` |
| `templates/usb-grub.cfg.tpl` | Per-stick GRUB config with server address and `viam_hostname=` |
| `templates/pi-user-data.tpl` | Pi cloud-init user-data |
| `templates/launchd/*.plist.tpl` | LaunchDaemons for dnsmasq, watcher, API and Bonjour |
| `http-server/default.conf.template` | nginx config; forwards exactly `POST /api/v1/install-reports` to the API. Rendered at container start; only `API_PORT` is substituted |
| `http-server/scripts/install-report.sh` | POSIX script the installer fetches and runs to report progress or failure; always exits 0 |
| `openapi/provisioner.yaml` | The API contract |
| `pxe-watcher/watcher.py` | Root watcher. `PxeTracker` assigns names to MACs; `LogTailer` follows the nginx access log and writes guards; a sweep thread fails silent installs every 30 seconds. `update_info` is the locked writer of `machine-info.json` |
| `pxe-watcher/queue_store.py` | Sole writer of `queue.json`; library for Python, CLI for the bash scripts |
| `pxe-watcher/event_journal.py` | Appends lifecycle events to `logs/events.jsonl` |
| `pxe-watcher/event_hub.py` | API-side tailer of the journal: ring buffer, `events_after(cursor)`, resync detection |
| `pxe-watcher/provisioner_service.py` | Request validation, credential staging, derived entry status, removal, `report_install` |
| `pxe-watcher/provisioner_api.py` | Stdlib `ThreadingHTTPServer` implementing the contract (REST + SSE) on `API_PORT` |
| `scripts/provision-batch.sh` | Appends machines to the queue; in full mode creates them in Viam and stages credentials (`fetch-credentials.py`) |
| `scripts/build-config.sh` | Renders `http-server/autoinstall/user-data` from `templates/user-data.tpl` |
| `scripts/setup-pxe-server.sh` | Extracts GRUB, kernel and initrd from the Ubuntu ISO (`just setup`) |
| `scripts/daemon.sh` | Renders the plists and installs, removes and reports on the LaunchDaemons |
| `scripts/api-service.sh` | Starts and stops the API and `dns-sd -R` in foreground mode via pid files in `logs/` |
| `scripts/lib/site-env.sh` | Reads settings from `config/site.env` without sourcing it; defaults `API_PORT`/`HTTP_PORT`/`INSTALL_TIMEOUT_MINUTES` to 8235/8234/45 |
| `scripts/pxe-subnet.sh` | Prints dnsmasq's proxy range for an interface, or for `PXE_PROXY_SUBNET` |
| `scripts/pick-server-iface.sh` | Scores UP IPv4 interfaces: default route first, then wired over wireless |
| `scripts/flash-pi-sd.sh`, `flash-batch.sh` | Pi SD card flashing |
| `scripts/flash-usb.sh`, `flash-usb-batch.sh` | x86 USB stick flashing |
| `scripts/tail-http-logs.sh` | Pretty-prints `logs/access.log` (`just logs`); writes nothing |
| `scripts/setup-wizard.sh` | Creates `config/site.env` and per-environment files |
| `Package.swift` | Swift package for v2: the `ProvisionerPXE`, `ProvisionerHelperXPC`, `ProvisionerAPI` and `ProvisionerKit` libraries, the `ProvisionerHelperCore`, `ViamAPI`, `ProvisionerPairHost` and `ProvisionerServer` libraries, the `ViamProvisioner` app, the `ProvisionerHelper` daemon, and the `provisioner-pxe`, `provisioner-helperctl`, `provisioner-probe`, `provisioner-pair` and `provisioner-server` executables |
| `Sources/ProvisionerPXE/PXEServer.swift` | Binds the DHCP (67), PXE (4011) and TFTP (69) sockets on one interface and publishes an `offered` event per answered discover and a `fileSent` event per completed TFTP read on `events` |
| `Sources/ProvisionerPXE/DHCP/` | BOOTP/DHCP codec and `ProxyDHCPResponder`, which answers PXE discovers with the boot server and filename (RFC 4578); `LeaseTable` holds the address each PXE client's DHCP request named, for `fileSent`'s MAC (`docs/decisions/0046-tftp-mac-from-dhcp-request.md`) |
| `Sources/ProvisionerPXE/TFTP/` | TFTP codec (RFC 1350), option negotiation (RFC 2347-2349), `TFTPRoot` path confinement, per-transfer state machine and handlers |
| `Sources/ProvisionerPXE/NetworkInterface.swift` | Looks up an interface's address, index and MTU by BSD name |
| `Tests/ProvisionerPXETests/` | Unit tests per component; `PXEServerTests` drives a running server over loopback UDP |
| `Sources/ProvisionerHelperXPC/` | The helper's XPC contract, which `ProvisionerServer` links: `ProvisionerHelperProtocol` (serve, stop, serving interface, write and remove TFTP-root files), `ProvisionerHelperEventsProtocol`, the JSON-coded `HelperEvent`, `HelperError`, and `HelperClient`, the async peer side |
| `Sources/ProvisionerHelperCore/` | `HelperService`, the listener delegate that fans PXE events out to every peer; `PXEHost`, which runs one `PXEServer` at a time with operations in arrival order; `TFTPRootFiles`; `PeerRequirement` |
| `Sources/ProvisionerHelper/` | The root launch daemon `com.bringingfire.viam-provisioner.helper`: the mach service listener over a TFTP root (`docs/decisions/0045-helper-serves-on-request.md`) |
| `App/LaunchDaemons/` | The helper's launchd plist; `scripts/bundle-app.sh` copies it to `Contents/Library/LaunchDaemons` for `SMAppService` |
| `Sources/provisioner-helperctl/` | Dev executable that drives the helper over XPC in place of `ProvisionerServer`: `serve`, `watch`, `status`, `stop`, `push`, `write`, `remove` |
| `Tests/ProvisionerHelperTests/` | Path confinement, peer requirements, event mapping, and a `HelperService` behind an anonymous XPC listener serving on lo0 |
| `Sources/ProvisionerAPI/` | Types generated from `openapi/provisioner.yaml` by swift-openapi-generator, through the `openapi.yaml` symlink |
| `Sources/ProvisionerKit/` | Client library. `ProvisionerClient` wraps the generated client; `Domain/` holds the types the app consumes and their mapping to the generated wire types; `WireCoding.swift` holds the ISO 8601 JSON coders; `ProvisionerError` is the error surface |
| `Sources/ProvisionerKit/QueueFeed.swift` | Snapshot, then the event stream from the snapshot's id; reconnects with backoff, resumes from the last event, resyncs by snapshot |
| `Sources/ProvisionerKit/InstallNotification.swift` | Maps an install-complete or install-failed `MachineEvent` to the text of a notification; identifier `install.<name>`, so a later outcome replaces the earlier one |
| `Sources/ProvisionerKit/InstallNotifier.swift` | Consumes `QueueFeed` updates and hands each ending install to a `NotificationPoster`; snapshots post nothing, replayed events post; a failed post is logged |
| `Sources/ProvisionerKit/UserNotificationPoster.swift` | `NotificationPoster` over `UNUserNotificationCenter`; needs a bundled app |
| `Sources/ProvisionerKit/ServerBrowser.swift` | Bonjour browse for `_viam-provisioner._tcp` with TXT `api=v1`, and validated manual addresses |
| `Sources/ViamAPI/` | Viam AppService client: `GRPCWeb.swift` frames unary gRPC-web calls over URLSession; `ViamAppClient` calls the service with a `BearerTokenProvider`'s token, refreshing it once on UNAUTHENTICATED, or with an API key it authenticates; `ViamOrgFleet` adapts it to `ViamFleet` for one org, and `ViamOrganizationLister` lists the account's orgs; `Generated/` holds checked-in swift-protobuf types from `scripts/gen-viam-protos.sh` (`docs/decisions/0037-grpc-web-to-viam.md`) |
| `Sources/ProvisionerKit/Pairing/` | App side of API-key pairing: ephemeral X25519 exchange and the four-digit comparison code (`PairingCrypto`), the `viam-provisioner://pair` link, wire messages and `PairingClient` |
| `Sources/ProvisionerKit/Viam/` | `ViamCLI` wraps the `viam` CLI: finds the binary, reads the login's token and account, runs `login` (reporting the device code it prints) and `logout`, lists orgs and creates keys; `CLITokenSource` holds the token in memory; `ViamSession` is the app's sign-in state (`docs/decisions/0043-sign-in-through-the-viam-cli.md`) |
| `Sources/ProvisionerKit/Organizations/` | `ViamOrganization` and `OrganizationsModel`, the orgs the signed-in account sees; `OrgCredential`, its Keychain store and `KeyDeleter`, which pairing uses |
| `Sources/ProvisionerKit/Environments/` | `Environment` and its validation; `FileEnvironmentStore` (JSON file plus a Keychain vault for secrets); `EnvironmentsModel`, which the editor and sidebar drive, with undo; `SHA512Crypt` for the OS password; `SiteEnvImport`, which maps a `config/environments/<env>.env` file and its packages file onto an environment |
| `Sources/ProvisionerKit/Queue/` | `QueueModel` follows one server's queue for the app: entries from snapshots and from a `GET /queue/{name}` per event, a reread every 15 s, and each machine's events seen this session; `ProvisioningRun` provisions one batch from an environment and keeps what wasn't queued for retry or deletion from Viam; `BatchHistory` stores the batches provisioned from this Mac; `ServerSelection` is the chosen server, from Bonjour or a typed address |
| `Sources/ProvisionerKit/Machines/` | `MachineName` and `MachineNaming` apply Viam's machine-name rule and pick the next `<prefix>-N` past the names in the location and the queue; `ViamFleet` is the protocol over Viam's machine calls; `MachineBatch` creates machines one at a time and deletes one that fails partway, and stops only when the key is rejected or the task is cancelled. After an unknown outcome (a timeout), a machine found under the name is reported as possibly left in Viam and never deleted, since another operator may have made it (decision 48) |
| `Sources/ProvisionerPairHost/` | Command side of pairing: `PairingHost` state machine, `PairingHTTPServer` loopback listener, and `KeyHandoff`, which creates the key after the operator confirms, releases it and waits for the app's result |
| `Sources/provisioner-pair/` | Pairing host (decision 0040): picks an org, shows the comparison code, creates the key after the operator confirms, releases it to the app |
| `Sources/ViamProvisioner/` | The macOS SwiftUI app: the server picker and sign-in status in the toolbar, the sign-in pane, the main window (Queue, History and environments in the sidebar; the live queue with a machine inspector, the batch history, the environment editor and its Provision sheet), Settings → Organizations, `--import-environment` behind `just import-env`, and `--helper-daemon` behind `just helper`. `scripts/bundle-app.sh` builds it into a bundle (`docs/decisions/0038-swiftpm-app-bundle.md`) |
| `Sources/provisioner-probe/` | Dev executable that exercises `ProvisionerKit` against a live API: `check`, `browse`, `watch`, `notify` (prints the notifications the app would post), `viam-locations`, `viam-batch`, `viam-delete-key` |
| `Sources/ProvisionerServer/` | The v2 server (Hummingbird). `Provisioner` is the actor that owns all state: provisioning, derived status, removal, install reports (`InstallReports.swift`) and live event fan-out. `Store/` holds `MachineStore` (queue, machine records, staged credentials and environments) and `EventJournal`. `HTTP/` holds `APIHandler` (the generated `APIProtocol`), the SSE stream, static files, and the error and body-limit middleware. `ServerMain` parses flags and runs the app in a `ServiceGroup` |
| `Sources/provisioner-server/` | Executable wrapper around `ServerMain` |
| `Tests/ProvisionerServerTests/` | Store, journal, report and fan-out tests against temp directories; REST, SSE and restart tests against a live server through ProvisionerKit's client and feed |
| `Tests/ProvisionerKitTests/` | Domain mapping, client, feed, browser, queue, run and history tests; `Support/` holds a scripted transport, a fake feed source, a fake fleet and `poll` |

## Data model

All under `http-server/machines/` unless noted. Every file the root watcher creates is chowned to the owner of that directory.

- **`queue.json`** — array of entries, written only by `queue_store.py` under an flock on `queue.lock` with temp-file-and-rename. `{"name", "assigned"}`; full mode adds `slot_id` (`slot-<name>`); PXE assignment adds `mac`; USB flashing adds `flashed_via`. A USB machine's failure markers live on its entry. Every lookup by name ignores case, since Viam treats such names as one machine (decision 41).
- **`slot-<name>/viam.json`** — full-mode credentials staged at provision time, before a MAC is known.
- **`<mac>/machine-info.json`** — one PXE machine: `name`, `mac`, `assigned_at`, `attempt`, `progress_at`, `completed_at`, `failed_at`/`failure_reason`/`failure_source` (`installer`, `timeout` or `reboot`), `armed`. Every change to an existing file goes through `watcher.update_info` (flock on `info.lock`).
- **`by-name/<name>/`** — credentials for USB machines, which fetch by name.
- **`netboot/grub/provisioned/<MAC>.cfg`** — the guard. Its presence makes GRUB exit to disk instead of installing.
- **`logs/events.jsonl`** — the event journal. Ids derive from the last line, read under the file's flock.
- **`logs/access.log`** — nginx's access log, mounted at `/var/log/pxe`, outside the served tree.
- **`~/Library/Application Support/Viam Provisioner/environments.json`** (app) — the app's environments, sorted by name, written atomically. Each carries `has…` flags for its secrets, never the secrets.
- **`~/Library/Application Support/Viam Provisioner/batches.json`** (app) — the batches provisioned from this Mac, newest first, written atomically: environment, mode, org and location names, server, the names queued, and a sentence per machine that wasn't. An unreadable file is reported and never overwritten.
- **UserDefaults `server.name`, `server.url`** (app) — the chosen provisioning server.
- **Keychain service `com.bringingfire.viam-provisioner.environment-secrets`** (app) — one generic-password item per environment ID holding the OS password's SHA-512 crypt hash, the WiFi password and the Tailscale key.
- **Swift server data directory** (`--data-dir`) — `queue.json` (entries in order, names as given), `machines/<name>.json` (attempt, stage, attempt start, progress, completion and failure), `credentials/<name>/viam.json` and `environment.json` (0600, directory 0700), `events.jsonl`. Keys are lowercased names. Whole files are written to a temp file, fsynced, renamed into place, and the directory then synced; a failed directory sync is logged and keeps the write. The directory must lie outside `--files`, checked after resolving symlinks and `..`, since that tree is served to the network.
- **`config/site.env`** — site settings, gitignored. `config/.server-address` holds the `IP:port` baked into USB sticks.

## Invariants

- **`queue.json` has one writer.** Scripts call `queue_store.py`'s CLI; the watcher and API import it.
- **The queue is append-only.** `provision` adds machines after the highest existing `<prefix>-N` and skips names already queued. `just clean` is the only wipe.
- **The watcher holds no state in memory.** It reads the queue and the MAC's `machine-info.json` on every PXE event, so `provision`, `reset`, `clean` and `unguard` take effect on a running daemon. A MAC that arrives with no slot is not remembered.
- **Guards are written on signs the installer is past its hostname fetch.** The watcher writes one on a 200 response to `GET /machines/<mac>/hostname` in the access log, and on a repeat PXE more than 60 seconds after assignment. The API writes one on a `done` report, and on progress past `identity` that clears a timeout failure.
- **The journal is the only IPC.** The root watcher and the operator-owned API both append to `logs/events.jsonl` under its flock; the API tails it for SSE. A journal write failure is logged and never blocks assignment, guards or a recorded failure.
- **Entry status comes from disk.** `queued`/`flashed`/`assigned`/`installing`/`installed`/`failed` derive from `queue.json`, `machine-info.json` and the guard on every read. `failed` is checked first, because a failure removes the guard and a missing guard alone reads as `assigned`. `install-complete` is decided by `completed_at`, stamped before the event is emitted.
- **Crash recovery completes, never re-assigns.** The watcher completes an entry already assigned to a MAC instead of consuming a second slot.
- **A failure removes the guard; the next PXE starts a new attempt.** A failed or `armed` MAC gets `attempt` + 1, a reset `assigned_at` and cleared markers, before the 60-second repeat-PXE rule is consulted. An installer failure replaces a timeout failure and then sticks; a timeout failure is cleared by later progress or a hostname fetch. A USB machine has no re-arm, so any progress after its failure clears it.
- **A repeat PXE with no sign of the installer is a failed boot.** Past the 60-second window, a machine with no progress report and no hostname-fetch guard records `install-failed` with source `reboot` and starts a new attempt. Machines assigned before attempts existed (no `attempt`) keep the old completion rule.
- **`done` completes a PXE install.** It stamps `completed_at` and emits `install-complete`, unless the machine is failed by the installer or armed by `just unguard`. A later PXE boot is the reboot the guard sends to disk and changes nothing. A repeat PXE still completes a machine whose `done` never arrived. A USB machine is not completed: `InstallComplete` requires a `mac`. See `docs/decisions/0035-complete-on-done.md`.
- **Installer reports carry no log text.** A reason is a fixed phrase plus at most the crash exception class, cleaned by the helper and again by the server.
- **The timeout is off unless passed.** The watcher's `--install-timeout-minutes` defaults to off; `just serve` and the plist pass `INSTALL_TIMEOUT_MINUTES`.
- **Daemons run on a stable interpreter.** System or Homebrew `python3` ≥ 3.9, never the venv; the code avoids 3.10-only syntax. The serving interface is baked into the plist at install. dnsmasq is stopped by pid file.
- **dnsmasq's proxy range follows the serving interface**, computed by `pxe-subnet.sh` at `just serve` or daemon install. `PXE_PROXY_SUBNET` overrides it.
- **The Swift PXE server serves only inside its TFTP root.** `TFTPRoot` rejects paths that resolve outside it. Block size is capped by the interface MTU, and concurrent transfers by `maxTransfers`; a request beyond the cap gets a TFTP error.
- **A `PXEServer` starts once and stops once.** `start()` throws on a server that is starting, running or stopped, so no second set of sockets replaces the first; a failed bind closes the sockets already bound, and a `stop()` during `start()` returns only after that start has closed them. `events` keeps only the newest `eventBufferLimit` unread events, since every discover, firmware retries included, yields one.
- **The helper binds nothing until a peer asks.** It stores no interface or boot file; `HelperClient` asks again after a restart (`docs/decisions/0045-helper-serves-on-request.md`).
- **The helper writes only inside its TFTP root.** `TFTPRootFiles` refuses absolute paths, empty, `.` or `..` components, and paths whose directory resolves outside the root through a symlink. It removes only regular files.
- **The Swift DHCP sockets bind 0.0.0.0 pinned to the interface.** They use `IP_BOUND_IF`, because on macOS a socket bound to a unicast address never receives broadcast discovers. See `docs/decisions/0028-bind-dhcp-to-interface.md`.
- **One process owns the Swift server's state.** The `Provisioner` actor reads and writes its data directory; nothing else does, so it takes no file locks. A record is saved before its event is journaled, and a journal failure is logged and loses only the event. A newly queued name starts with no record and no staged files; anything left under its key is cleared first. An unreadable machine record is logged and skipped, and an append after a torn journal line starts a new line.
- **Swift server status derives from the machine record:** `failed`, then `installed`, then `installing` once any report arrived, else `queued`. `done` completes an install. Removal is refused only while `installing`.
- **Swift server 500s carry no Swift error text.** A failure the server names answers with a fixed sentence; anything else answers `internal error`. The underlying error goes to the log.
- **Swift event streams end on graceful shutdown.** Hummingbird waits for in-flight responses, so each SSE body finishes itself when shutdown begins. A client that disconnects frees its stream slot at the next write, within one keepalive. A client that falls 256 events behind is dropped, and any end of a stream releases its slot.
- **The Python server ignores `environment` in provision requests.** `ProvisionRequest.environment` carries the settings the Swift server renders into a machine's install config; the Python server accepts and drops it, and renders from `config/site.env`.
- **The pairing key is created only after the operator confirms the code, and released only after the app commits to its public key.** Cancel, decline or timeout before creation leave no key in Viam. After creation, every failure path prints the key's name and where to delete it. See `docs/decisions/0040-pair-api-keys-from-the-viam-cli.md`.
- **The app takes queue status from the server, never from events.** `QueueModel` replaces entries from `GET /queue` and, for each event not already in the snapshot, from `GET /queue/{name}`; a 404 removes the entry. Queueing machines emits no event, so it rereads the queue every 15 s and after each batch. Its reads run one at a time, so an older answer never replaces a newer one (`docs/decisions/0047-queue-status-from-server-reads.md`).
- **A machine created in Viam is either queued or reported.** `ProvisioningRun` lists each one the server didn't add, offers to resend those whose send failed, and deletes them from Viam on request.
- **The Mac app holds the viam CLI's token in memory only.** It reads it from `print-access-token`'s stdout; the CLI also prints it to stderr, so a failed read carries neither stream. The app never runs `viam login` over an existing login.
- **A cancelled CLI call returns only after the child exits.** `ViamCLI.processRunner` terminates the child on cancellation and waits on its termination handler; `Process.terminationStatus` raises while the child runs.
- **`DeleteKey` returning NOT_FOUND counts as deleted** (`docs/decisions/0039-not-found-counts-as-deleted.md`).
- **The app never stores an OS password, only its SHA-512 crypt hash.** Environment secrets live in the Keychain and the JSON file carries only flags, which the store derives from the secrets it holds. `just import-env` replaces an environment of the same name, keeping its ID and overwriting edits made in the app.
- **NIC names are discovered at install time.** The autoinstall config hardcodes no interface names.

## Boundaries

- **Targets know only the file server's `host:port`.** nginx forwards exactly `POST /api/v1/install-reports` (16 KiB body limit) to the API at `host.docker.internal`. The API's own port is open to any host on the network, targets included; the split is two processes, not an access boundary.
- **The API runs as the operator, unauthenticated, on `0.0.0.0`.** It assumes a trusted lab network. It skips `getfqdn()` at bind so startup never waits on reverse DNS.
- **The org API key stays on the host.** Targets receive only their own `viam.json`.
- **The pairing listener binds loopback and caps request bodies at 64 KiB.**
- **The helper accepts XPC peers by code signature.** A team-signed helper requires the peer's team, and `provisioner-helperctl` passes it, so every local user of a server Mac can drive the helper. An ad-hoc helper requires the identifiers `com.bringingfire.viam-provisioner.server` or `.helperctl`, which any ad-hoc binary can claim, and a peer running as the user who owns the helper's executable.
- **The helper's TFTP root is root's alone.** Running as root, it refuses to start on a root owned by another user or writable by group or others; writes check the resolved directory before creating anything.
- **Under `just serve-usb` no watcher runs.** The API appends installer reports to the journal itself.

## API

`openapi/provisioner.yaml` is the contract. `pxe-watcher/test_contract.py` validates real responses and journal events against it. Every SSE frame's `data` carries `id`, `type` and `timestamp`. `GET /queue` returns `last_event_id` for snapshot-then-stream; a `resync` event means the client's `Last-Event-ID` can't be served and it should refetch `/queue`. The API advertises `_viam-provisioner._tcp` over Bonjour with `api=v1` in the TXT record.

## Boot order after install

The installer moves the disk above network boot with `efibootmgr`, from late-commands and again from a first-boot service, because efivars are not always writable in the installer chroot. Some firmware restores network-first anyway (#4); every reboot then network-boots and the guard sends it to disk. A machine whose firmware boots the disk first never PXEs again after install, so it stays `installing`.
