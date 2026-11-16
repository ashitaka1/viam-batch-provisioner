# 52. Each machine fetches its config and secrets from a path carrying its token

Date: 2026-11-16

## Status

Accepted. #106 builds it; #107 (PXE) and #153 (USB) put the path on the machine's kernel command line.

## Context

`scripts/build-config.sh` renders one `user-data` for every machine, holding the WiFi password, and stages it under `/autoinstall/` beside the shared Tailscale key under `/config/`. Any host on the serving LAN can fetch both. The Swift server replaces it, rendering each machine's config from the `environment` in its provision request. The provisioning API is unauthenticated and listens on 0.0.0.0.

A machine's secrets are its Viam credentials, the WiFi password, and the site's Tailscale auth key, which every machine shares.

## Decision

- **Token.** Provisioning a machine that carries an `environment` mints a random 128-bit token, stored 0600 beside the machine's staged files.
- **Path.** The machine fetches from `/machines/by-name/<name>/<token>/`: `meta-data`, `vendor-data`, `user-data` (rendered), `viam.json`, `tailscale.key`. A wrong token, an unknown file, or a machine that has finished gets 404. Tokens compare in constant time. `/machines/by-name/<name>/` without a token serves nothing. `StaticFiles` never serves `/machines/` from disk, and refuses `/config/` and `/autoinstall/`.
- **Once per install attempt.** `user-data`, `viam.json` and `tailscale.key` are each served once, until a recorded failure or a PXE offer (decision 51) re-arms them. Nothing is served after `done`. The served time is saved on the machine's record before the response goes out; a failed save answers 500 without the file. The Tailscale key is the site's shared key, served once to each machine per attempt.
- **Delivery.** The token appears only in the provision response, to the client that sent the secrets. The machine receives it on its kernel command line as `ds=nocloud-net;s=http://<server>/machines/by-name/<name>/<token>/ viam_hostname=<name>`. The token may appear in the machine's logs.
- **Rendering.** The server renders `templates/user-data.tpl` with envsubst semantics: only the variables `build-config.sh` substitutes, plus `MACHINE_URL`, in both `$VAR` and `${VAR}` forms. `PXE_SERVER` comes from the request's Host header after validation. When `MACHINE_URL` is set, the late-commands fetch `viam.json` and the Tailscale key from it; `build-config.sh` renders it empty. Values are escaped for their context: YAML double quotes for the SSH key and password hash; YAML, then the unquoted NETPLAN heredoc (`\`, `$`, backtick), for the WiFi SSID and password. Provisioning rejects control characters in any field, and checks username, timezone and package names against fixed patterns.

## Consequences

- A host that holds a machine's token before the machine fetches its secrets (someone with its USB stick, or a MAC spoofer per decision 51) can take them. The machine's own fetch then gets 404 and its install fails.
- Every installed machine holds the site's Tailscale key. Serving it once limits which hosts fetch it, not where the key ends up.
- A token in a log fetches nothing once its secrets are spent.
- If cloud-init fetches `user-data` more than once in an installer boot, the later fetch gets 404. Checked on hardware with #107.
- The bash/Python path renders `MACHINE_URL` empty and is unchanged.

## Alternatives

A Tailscale key minted per machine through the Tailscale API, or an ephemeral single-use auth key, keeps the site key off the machines and needs automation and credentials for the Tailscale account. Serving `/machines/by-name/<name>/` without a token hands the secrets to any host that knows the name.
