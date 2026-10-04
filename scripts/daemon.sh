#!/usr/bin/env bash
# Install, remove, or inspect the launchd daemons that keep the PXE server
# running: dnsmasq (proxy DHCP + TFTP), pxe-watcher, the provisioner API
# and its Bonjour advertisement. dnsmasq and the watcher run as root;
# the API and dns-sd run as the operator. The nginx container is managed
# by docker compose and its restart policy, not by launchd.
#
# Usage:
#   scripts/daemon.sh install [--interface IFACE] [--python PATH]
#       The proxy-DHCP range comes from scripts/pxe-subnet.sh for IFACE.
#       API_PORT and HTTP_PORT come from config/site.env (8235 / 8234).
#   scripts/daemon.sh uninstall
#   scripts/daemon.sh status
#   scripts/daemon.sh installed      # exit 0 if the plists are installed
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/templates/launchd"
RENDER_DIR="${REPO_ROOT}/config/launchd"
LOG_DIR="${REPO_ROOT}/logs"
DAEMON_DIR="/Library/LaunchDaemons"
LABELS=(com.viam.provisioner.dnsmasq com.viam.provisioner.watcher com.viam.provisioner.api com.viam.provisioner.bonjour)

die() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck source=lib/site-env.sh
source "${REPO_ROOT}/scripts/lib/site-env.sh" || die "bad port setting in config/site.env"

installed() {
    [[ -f "${DAEMON_DIR}/com.viam.provisioner.watcher.plist" ]]
}

pick_python() {
    local candidates=("${PROVISIONER_PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3)
    local p
    for p in "${candidates[@]}"; do
        [[ -n "$p" && -x "$p" ]] || continue
        if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

render() {
    local label="$1"
    sed -e "s|@REPO@|${REPO_ROOT}|g" \
        -e "s|@PYTHON@|${PYTHON}|g" \
        -e "s|@DNSMASQ@|${DNSMASQ}|g" \
        -e "s|@IFACE@|${IFACE}|g" \
        -e "s|@DHCP_RANGE@|${DHCP_RANGE}|g" \
        -e "s|@USER@|${OPERATOR}|g" \
        -e "s|@API_PORT@|${API_PORT}|g" \
        -e "s|@HTTP_PORT@|${HTTP_PORT}|g" \
        -e "s|@SERVER_NAME@|${SERVER_NAME}|g" \
        "${TEMPLATE_DIR}/${label}.plist.tpl" > "${RENDER_DIR}/${label}.plist"
}

cmd_install() {
    local iface="" python=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interface) iface="$2"; shift 2 ;;
            --python)    python="$2"; shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [[ "$(uname -s)" == "Darwin" ]] || die "launchd daemons are macOS-only"

    # A root daemon cannot read these directories without a TCC grant, and
    # the failure is silent.
    case "$REPO_ROOT" in
        "$HOME"/Desktop/*|"$HOME"/Documents/*|"$HOME"/Downloads/*)
            die "Repo is under a TCC-protected folder (${REPO_ROOT}). Move it elsewhere (e.g. ~/eng) before installing daemons." ;;
    esac

    if ! installed; then
        pid_alive "${LOG_DIR}/dnsmasq.pid" && die "A foreground dnsmasq is running (just serve). Stop it first."
        pid_alive "${LOG_DIR}/api.pid" && die "A foreground API is running (just serve). Stop it first."
    fi

    DNSMASQ="$(command -v dnsmasq || true)"
    [[ -n "$DNSMASQ" ]] || die "dnsmasq not found. Run 'just doctor'."

    PYTHON="${python:-$(pick_python || true)}"
    [[ -n "$PYTHON" ]] || die "No python3 >= 3.9 found. Install with: brew install python"

    if [[ -z "$iface" ]]; then
        iface="$("${REPO_ROOT}/scripts/pick-server-iface.sh" --interactive | awk '{print $1}')"
    fi
    [[ -n "$iface" ]] || die "No interface selected"
    IFACE="$iface"
    DHCP_RANGE="$("${REPO_ROOT}/scripts/pxe-subnet.sh" "$IFACE")"

    OPERATOR="$(id -un)"
    SERVER_NAME="$(server_name)"

    mkdir -p "$LOG_DIR" "$RENDER_DIR"
    # The operator-owned daemons append to these; create them as the operator.
    touch "${LOG_DIR}/api.log" "${LOG_DIR}/bonjour.log"
    local label
    for label in "${LABELS[@]}"; do
        render "$label"
    done

    echo "Installing launchd daemons (sudo)..."
    for label in "${LABELS[@]}"; do
        sudo launchctl bootout "system/${label}" 2>/dev/null || true
        sudo install -o root -g wheel -m 644 "${RENDER_DIR}/${label}.plist" "${DAEMON_DIR}/${label}.plist"
        sudo launchctl bootstrap system "${DAEMON_DIR}/${label}.plist"
        echo "  ${label} loaded"
    done
    echo ""
    echo "Interface:  ${IFACE}"
    echo "Proxy DHCP: ${DHCP_RANGE}"
    echo "Python:     ${PYTHON}"
    echo "API:        http://localhost:${API_PORT}/api/v1/  (Bonjour: _viam-provisioner._tcp, as ${OPERATOR})"
    echo "Logs:       ${LOG_DIR}/{watcher,dnsmasq,api,bonjour}.log"
}

cmd_uninstall() {
    installed || { echo "Daemons are not installed."; return 0; }
    local label
    for label in "${LABELS[@]}"; do
        sudo launchctl bootout "system/${label}" 2>/dev/null && echo "  ${label} stopped" || true
        sudo rm -f "${DAEMON_DIR}/${label}.plist"
    done
    echo "Daemons removed."
}

cmd_status() {
    if ! installed; then
        echo "Daemons: not installed (just serve-daemon)"
        return 0
    fi
    local label out state pid
    for label in "${LABELS[@]}"; do
        out="$(launchctl print "system/${label}" 2>/dev/null || true)"
        state="$(echo "$out" | awk -F'= ' '/^\tstate = /{print $2; exit}')"
        pid="$(echo "$out" | awk -F'= ' '/^\tpid = /{print $2; exit}')"
        printf '  %-32s %s%s\n' "$label" "${state:-not loaded}" "${pid:+ (pid ${pid})}"
    done
    if [[ -f "${RENDER_DIR}/com.viam.provisioner.watcher.plist" ]]; then
        local py
        py="$(sed -n 's|.*<string>\(.*python3[^<]*\)</string>.*|\1|p' "${RENDER_DIR}/com.viam.provisioner.watcher.plist" | head -1)"
        [[ -n "$py" ]] && echo "  python: ${py}"
    fi
    "${REPO_ROOT}/scripts/api-service.sh" status
    if [[ -f "${LOG_DIR}/watcher.log" ]]; then
        echo ""
        echo "  watcher.log (last 5 lines):"
        tail -n 5 "${LOG_DIR}/watcher.log" | sed 's/^/    /'
    fi
}

case "${1:-}" in
    install)   shift; cmd_install "$@" ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    installed) installed ;;
    *) echo "Usage: $0 install [--interface IFACE] [--python PATH] | uninstall | status | installed" >&2; exit 1 ;;
esac
