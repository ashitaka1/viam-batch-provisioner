# Flutter App Spec

A macOS desktop GUI for the Viam Lab Provisioner, coexisting with the CLI.
Both read and write the same files on disk, so either can be used
interchangeably. No backend server; the app shells out to the same scripts
under `cli/` and watches the filesystem directly.

See `CLAUDE.md` for the CLI architecture this app wraps.

## Scope

**macOS only** for now. The CLI uses macOS-specific tooling (`diskutil`,
`osascript`), so the Flutter runner targets macOS exclusively. Platform-
specific code is isolated in `app/lib/core/platform_utils.dart` to keep a
Linux extension feasible, but Linux is not implemented or tested.

**No Docker dependency for the GUI.** The CLI uses Docker + nginx to serve
files on port 8234. The GUI replaces this with an embedded `dart:io`
`HttpServer` that serves the same files from `http-server/`, making the
app self-contained. The CLI's Docker path is unchanged; both approaches
serve identical content on the same port.

## Repo Layout

```
richmond/
├── cli/                          # Shell scripts (CLI entry points)
├── app/                          # Flutter desktop app (macOS only)
│   ├── pubspec.yaml
│   ├── macos/                    # macOS runner (Flutter-generated)
│   └── lib/
│       ├── main.dart
│       ├── app.dart              # CupertinoApp, light/dark theme
│       ├── core/
│       │   ├── repo_root.dart    # walk up from executable to find justfile
│       │   ├── platform_utils.dart   # macOS privilege escalation (osascript)
│       │   ├── process_runner.dart   # Process.start wrapper with stdout streaming
│       │   ├── file_watcher.dart     # debounced FileSystemEntity.watch
│       │   └── http_server.dart      # embedded HttpServer (Phase 4)
│       ├── data/
│       │   ├── env_config.dart
│       │   ├── queue_repository.dart
│       │   └── environment_repository.dart
│       ├── models/
│       │   ├── environment.dart
│       │   ├── queue_entry.dart
│       │   ├── batch.dart
│       │   ├── service_status.dart
│       │   └── flash_state.dart
│       ├── providers/            # Riverpod providers
│       ├── features/
│       │   ├── batch/            # new batch form, provision stage, sidebar
│       │   ├── boot/             # x86 PXE stage (Phase 4)
│       │   ├── flash/            # Pi SD card wizard (Phase 5)
│       │   ├── verify/           # post-provision summary (Phase 6)
│       │   ├── settings/         # drawer: env CRUD, NIC, theme
│       │   └── shell/            # app shell: toolbar + sidebar + main panel
│       └── theme/
```

## Information Architecture

**Batch-centric, not function-centric.** The primary object is a Batch — a
named group of machines being provisioned — and the UI follows batch
lifecycle stages. Config and settings are chrome-level context, not
workflow destinations.

```
+------------------------------------------------------------------+
| TOOLBAR                                                          |
|  [Environment: tcos-lab v]   [Services: ●●○]          [Gear]    |
+-----------------------------+------------------------------------+
| SIDEBAR                     | MAIN PANEL                        |
|                             |                                    |
| hackathon-pi (10 machines)  |  (current stage content)           |
|   Mode: full | Pi SD        |                                    |
|                             |                                    |
|  1. [✓] Provision   10/10  |                                    |
|  2. [→] Flash         2/10 |                                    |
|  3. [ ] Verify         --  |                                    |
|                             |                                    |
| ✓ hackathon-pi-1            |                                    |
| → hackathon-pi-3  flashing  |                                    |
| ○ hackathon-pi-4            |                                    |
|                             |                                    |
| [New Batch] [Reset]        |                                    |
+-----------------------------+------------------------------------+
```

### Toolbar
- **Environment dropdown** — like a Git branch picker. Switches active env
  by re-symlinking `config/site.env`.
- **Service health indicators** — dots for HTTP (embedded), dnsmasq,
  watcher. Clickable to expand start/stop controls.
- **Settings gear** — opens a drawer for environment CRUD, NIC selection,
  theme, Pi OS image management.

### Sidebar
- Batch header (name, machine count, provision mode, target type)
- Stage stepper with completion counts:
  - Pi path: Provision → Flash → Verify
  - x86 path: Provision → Boot → Verify
  - Clicking a stage swaps the main panel
- Machine list with live status icons (✓ done, → in progress, ○ waiting),
  updated via `queue.json` file watch
- New Batch / Reset / Clear actions at bottom

### Main Panel (adapts to selected stage)

- **No batch** → New Batch form (prefix, count, target type, provision
  mode) → runs `cli/provision-batch.sh`.
- **Provision stage** → streams output from `provision-batch.sh`, then
  shows summary.
- **Flash stage (Pi)** → guided card-by-card wizard: detect via
  `diskutil list` diff → confirm → `dd` with progress → next machine.
- **Boot stage (x86)** → Start/Stop Services (embedded HTTP + dnsmasq +
  watcher). Live PXE assignment events.
- **Verify stage** → summary table of all machines with final status.

### Settings Drawer
- Environments (list, create, edit, delete; active highlighted)
- Network interface selector
- Light/dark theme toggle
- Repo root display, Pi OS image path + download

## Architecture Decisions

### macOS only (for now)
Platform-specific code lives in `app/lib/core/platform_utils.dart` —
isolated so Linux support can be added later by implementing the same
interface with `pkexec`, `lsblk`, etc. A GitHub issue tracks the Linux
extension.

### Embedded HTTP server (no Docker)
`app/lib/core/http_server.dart` runs an in-process `dart:io` `HttpServer`
on port 8234 serving `http-server/`. Lifecycle starts when Boot stage
"Start Services" is clicked, stops on exit. The CLI's
`just up` / `docker compose up` path is unchanged; both serve the same
directory identically.

### State management: Riverpod
Natural fit for watching external state (filesystem, process output) via
`StreamProvider`. Providers auto-dispose when UI navigates away. Less
ceremony than Bloc for a read-heavy app where most state changes come
from file watches, not user interaction.

### Cupertino UI
Native macOS look using `CupertinoApp`, `CupertinoPageScaffold`,
`CupertinoNavigationBar`. Light/dark follows `MediaQuery.platformBrightness`
with user override.

### Script interaction
The app calls the same shell scripts the CLI uses via `Process.start()`.
Stdout/stderr stream line-by-line into Riverpod providers. Scripts find
`REPO_ROOT` themselves — the app just provides absolute script paths. The
app never reimplements script logic in Dart.

### Privilege escalation (macOS)
`osascript -e 'do shell script "..." with administrator privileges'`
triggers the native macOS password dialog. `acquireSudo()` caches
credentials with `sudo -v` so subsequent `sudo -n` calls run
non-interactively until the timestamp expires. Needed for: dnsmasq,
pxe-watcher (tcpdump), `dd` (SD card).

### macOS sandbox disabled
`com.apple.security.app-sandbox` is `false` in both entitlements files.
This is a local operator tool, not App Store — the sandbox is
incompatible with reading arbitrary repo files and spawning repo scripts.

### File watching
`dart:io` `FileSystemEntity.watch()` via kqueue. Watches parent
directories (not individual files) for robustness against
truncate+recreate, with a 200ms debounce to coalesce rapid writes.

### Key packages
`flutter_riverpod`, `path`, `go_router` (pending), `freezed` +
`json_serializable` (pending), `macos_ui` (evaluated per-need). No
external HTTP client, no SQLite, no bloc.

## Implementation Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Repo restructure (`scripts/` → `cli/`), justfile update, Linux tracking issue | Done |
| 1 | Flutter skeleton, Cupertino shell, env CRUD, settings drawer, light/dark theme | Done |
| 2 | Batch model, queue repository + live file watch, New Batch form, sidebar dashboard, stage stepper | Done |
| 3 | Process runner, privilege helpers, provision stage streaming output, Reset/Clear batch actions | Done |
| 4 | Embedded HTTP server, service lifecycle (HTTP + dnsmasq + watcher), Boot stage UI, health indicators | Pending |
| 5 | Pi SD card flash state machine, device detection, dd-with-progress wizard | Pending |
| 6 | Verify stage summary, graceful shutdown, NIC selector, theme toggle, edge cases | Pending |

### Verification checkpoints
1. After Phase 0: `just status` works after rename.
2. After Phase 1: create env in GUI → `source config/site.env` from CLI → values match.
3. After Phase 2: `just provision test 3` from CLI → queue appears in app sidebar within 1s.
4. After Phase 3: provision from GUI → `cat http-server/machines/queue.json` matches.
5. After Phase 4: start services in GUI → `curl localhost:8234/autoinstall/meta-data` returns content → `pgrep dnsmasq` confirms running.
6. After Phase 5: flash SD card from GUI → boot Pi → SSH in → verify config.
7. After Phase 6: close app → all child processes terminated.

## Future Work

- **Linux desktop support.** Implement `platform_utils.dart` with
  `pkexec`, `lsblk`, `ip link`. Generate Linux runner. CLI scripts using
  `diskutil` will need a Linux equivalent.
- **Viam/Tailscale check-in status in Verify stage.** Reach out to the
  respective APIs to confirm machines are online, not just installed.
