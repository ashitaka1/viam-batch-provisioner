# Settings from config/site.env for scripts that must not `source` it.
# Expects REPO_ROOT. Defines read_setting, server_name, pid_alive and
# exports API_PORT, HTTP_PORT and INSTALL_TIMEOUT_MINUTES with their defaults.
# Returns non-zero if one of them is not a number.

SITE_CONFIG="${SITE_CONFIG:-${REPO_ROOT}/config/site.env}"

read_setting() {
    [[ -f "$SITE_CONFIG" ]] || return 0
    sed -n -e "s/^\(export \)\{0,1\}$1=//p" "$SITE_CONFIG" | tr -d '"'"'" | tail -1
}

server_name() {
    scutil --get LocalHostName 2>/dev/null || hostname -s
}

pid_alive() {
    [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

API_PORT="${API_PORT:-$(read_setting API_PORT)}"
API_PORT="${API_PORT:-8235}"
HTTP_PORT="${HTTP_PORT:-$(read_setting HTTP_PORT)}"
HTTP_PORT="${HTTP_PORT:-8234}"
INSTALL_TIMEOUT_MINUTES="${INSTALL_TIMEOUT_MINUTES:-$(read_setting INSTALL_TIMEOUT_MINUTES)}"
INSTALL_TIMEOUT_MINUTES="${INSTALL_TIMEOUT_MINUTES:-45}"
export API_PORT HTTP_PORT INSTALL_TIMEOUT_MINUTES

[[ "$API_PORT" =~ ^[0-9]+$ && "$HTTP_PORT" =~ ^[0-9]+$ ]] || {
    echo "ERROR: API_PORT/HTTP_PORT must be numbers (got '$API_PORT' / '$HTTP_PORT')" >&2
    return 1
}
[[ "$INSTALL_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || {
    echo "ERROR: INSTALL_TIMEOUT_MINUTES must be a number of minutes, 0 to turn it off (got '$INSTALL_TIMEOUT_MINUTES')" >&2
    return 1
}
