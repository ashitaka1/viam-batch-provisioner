#!/usr/bin/env bash
# Run the provisioner API and its Bonjour advertisement in foreground mode
# (`just serve`, `just serve-usb`), tracked by pid files in logs/. In daemon
# mode both run under launchd (scripts/daemon.sh) and this script only
# reports.
#
# Usage:
#   scripts/api-service.sh start | stop | status
#   scripts/api-service.sh port        # print the configured API port
#   scripts/api-service.sh install-timeout   # print the install timeout in minutes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
API_PID="${LOG_DIR}/api.pid"
BONJOUR_PID="${LOG_DIR}/bonjour.pid"

die() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck source=lib/site-env.sh
source "${REPO_ROOT}/scripts/lib/site-env.sh" || die "bad setting in config/site.env"

responding() {
    curl -fsS --max-time 2 "http://localhost:${API_PORT}/api/v1/status" >/dev/null 2>&1
}

cmd_start() {
    if "${REPO_ROOT}/scripts/daemon.sh" installed; then
        echo "  API runs under launchd (daemons installed); nothing to start."
        return 0
    fi
    mkdir -p "$LOG_DIR"
    if pid_alive "$API_PID"; then
        echo "  API already running (pid $(cat "$API_PID"))"
    else
        local python="${PROVISIONER_PYTHON:-$(command -v python3)}"
        nohup "$python" "${REPO_ROOT}/pxe-watcher/provisioner_api.py" \
            --port "$API_PORT" --http-port "$HTTP_PORT" --server-name "$(server_name)" \
            >> "${LOG_DIR}/api.log" 2>&1 &
        echo $! > "$API_PID"
        sleep 1
        pid_alive "$API_PID" || { rm -f "$API_PID"; die "API failed to start; see ${LOG_DIR}/api.log"; }
        echo "  API listening on :${API_PORT} (pid $(cat "$API_PID"))"
    fi
    if command -v dns-sd >/dev/null; then
        if pid_alive "$BONJOUR_PID"; then
            echo "  Bonjour already advertising (pid $(cat "$BONJOUR_PID"))"
        else
            nohup dns-sd -R "$(server_name)" _viam-provisioner._tcp local "$API_PORT" api=v1 \
                >> "${LOG_DIR}/bonjour.log" 2>&1 &
            echo $! > "$BONJOUR_PID"
            echo "  Bonjour advertising _viam-provisioner._tcp on :${API_PORT}"
        fi
    fi
}

cmd_stop() {
    local label pid_file
    for label in api bonjour; do
        pid_file="${LOG_DIR}/${label}.pid"
        if pid_alive "$pid_file"; then
            kill "$(cat "$pid_file")" 2>/dev/null && echo "  ${label} stopped" || true
        fi
        rm -f "$pid_file"
    done
}

cmd_status() {
    if "${REPO_ROOT}/scripts/daemon.sh" installed; then
        if [[ ! -f /Library/LaunchDaemons/com.viam.provisioner.api.plist ]]; then
            echo "  api: not installed (older daemon set); re-run 'just serve-daemon'"
        elif responding; then
            echo "  api: responding on :${API_PORT} (launchd)"
        else
            echo "  api: not responding on :${API_PORT} (launchd; see logs/api.log)"
        fi
        return 0
    fi
    if pid_alive "$API_PID"; then
        echo "  api: running on :${API_PORT} (pid $(cat "$API_PID"), just serve)"
    else
        echo "  api: stopped"
    fi
    if pid_alive "$BONJOUR_PID"; then
        echo "  bonjour: advertising (pid $(cat "$BONJOUR_PID"))"
    else
        echo "  bonjour: stopped"
    fi
}

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    port)   echo "$API_PORT" ;;
    http-port) echo "$HTTP_PORT" ;;
    install-timeout) echo "$INSTALL_TIMEOUT_MINUTES" ;;
    *) echo "Usage: $0 start | stop | status | port | http-port | install-timeout" >&2; exit 1 ;;
esac
