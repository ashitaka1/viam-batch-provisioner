#!/usr/bin/env bash
# Records this Mac's codesigning identity for `just app` in config/signing.env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_CONFIG="${REPO_ROOT}/config/signing.env"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
APPLE_CA_URL="https://www.apple.com/certificateauthority"

current=""
if [[ -f "$SIGNING_CONFIG" ]]; then
    current=$(sed -n 's/^CODESIGN_IDENTITY=//p' "$SIGNING_CONFIG" | tr -d '"' | tail -1)
fi

# PEM of the keychain certificate with this name and SHA-1 hash.
cert_pem() {
    security find-certificate -a -Z -p -c "$2" 2>/dev/null |
        awk -v h="$1" '/^SHA-1 hash:/ { take = ($3 == h) } take && /BEGIN/,take && /END/'
}

# One field (CN, OU, O) of a certificate's subject or issuer, read from PEM on stdin.
name_field() {
    openssl x509 -noout "-$1" -nameopt sep_multiline,utf8 2>/dev/null |
        sed -n "s/^ *$2=//p" | head -1
}

# Apple's download URL for an intermediate, by its CN and OU.
intermediate_url() {
    case "$1" in
        "Apple Worldwide Developer Relations Certification Authority") echo "${APPLE_CA_URL}/AppleWWDRCA$2.cer" ;;
        "Developer ID Certification Authority") echo "${APPLE_CA_URL}/DeveloperID$2CA.cer" ;;
    esac
}

# Whether the keychains hold an unexpired certificate with this CN and OU.
has_intermediate() {
    local pems pem
    pems=$(security find-certificate -a -p -c "$1" 2>/dev/null) || return 1
    while IFS= read -r -d $'\x1e' pem; do
        if [[ "$(name_field subject OU <<<"$pem")" == "$2" ]] &&
            openssl x509 -noout -checkend 0 <<<"$pem" >/dev/null 2>&1; then
            return 0
        fi
    done < <(awk '/BEGIN/ { pem = "" } { pem = pem $0 "\n" } /END/ { printf "%s\x1e", pem }' <<<"$pems")
    return 1
}

install_intermediate() {
    local url=$1 dir file
    dir=$(mktemp -d)
    file="${dir}/intermediate.cer"
    if ! curl -fsSL -o "$file" "$url"; then
        echo "Download failed: $url"
        rm -rf "$dir"
        return 1
    fi
    if ! security verify-cert -c "$file" >/dev/null 2>&1; then
        echo "Not installed: $url doesn't chain to a trusted root."
        rm -rf "$dir"
        return 1
    fi
    security import "$file" -k "$LOGIN_KEYCHAIN" >/dev/null
    rm -rf "$dir"
    echo "Installed $url"
}

# Identities as "hash<TAB>name", all of them and the valid ones.
list_identities() {
    security find-identity "$@" -p codesigning 2>/dev/null |
        sed -n -e '/Valid identities only/q' -e 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\([^"]*\)".*$/\1	\2/p'
}

load_identities() {
    all=$(list_identities)
    valid=$(list_identities -v)
    untrusted=$(grep -v -F -x -f <(printf '%s\n' "$valid") <<<"$all" || true)
}

load_identities

# Offer each missing intermediate once.
offered=""
while IFS=$'\t' read -r hash name <&3; do
    [[ -z "$hash" ]] && continue
    pem=$(cert_pem "$hash" "$name")
    if ! openssl x509 -noout -checkend 0 <<<"$pem" >/dev/null 2>&1; then
        echo "Expired: $name"
        continue
    fi
    cn=$(name_field issuer CN <<<"$pem")
    ou=$(name_field issuer OU <<<"$pem")
    if has_intermediate "$cn" "$ou"; then
        echo "Not trusted: $name"
        continue
    fi
    url=$(intermediate_url "$cn" "$ou")
    echo "Not trusted: $name"
    echo "  Missing intermediate: $cn $ou"
    if [[ -z "$url" ]]; then
        echo "  Get it from ${APPLE_CA_URL}/"
        continue
    fi
    case "$offered" in *"|$url|"*) continue ;; esac
    offered="${offered}|$url|"
    read -r -p "  Install it from apple.com? [Y/n] " answer
    [[ "$answer" =~ ^[Nn] ]] || install_intermediate "$url" || true
done 3<<<"$untrusted"
[[ -n "$offered" ]] && load_identities

names=()
labels=()
while IFS=$'\t' read -r hash name; do
    [[ -z "$hash" ]] && continue
    org=$(cert_pem "$hash" "$name" | name_field subject O)
    names+=("$name")
    labels+=("${name}${org:+  $org}")
done <<<"$valid"

if [[ -z "$all" ]]; then
    echo "No signing identities. Create one in Xcode: Settings > Accounts > Manage Certificates > + > Apple Development."
fi

# Default: the current setting, else the first Developer ID, else the first Apple Development,
# else ad hoc.
count=${#names[@]}
adhoc=$((count + 1))
default=""
for prefix in "Developer ID Application:" "Apple Development:"; do
    for ((i = 0; i < count; i++)); do
        [[ -z "$default" && "${names[$i]}" == "$prefix"* ]] && default=$((i + 1))
    done
done
for ((i = 0; i < count; i++)); do
    [[ -n "$current" && "${names[$i]}" == "$current" ]] && default=$((i + 1))
done
default=${default:-$adhoc}

echo "Signing identity for 'just app' (now: ${current:-ad hoc})"
for ((i = 0; i < count; i++)); do echo "  $((i + 1))) ${labels[$i]}"; done
echo "  ${adhoc}) Ad hoc"

while true; do
    read -r -p "Choice [${default}]: " choice
    choice=${choice:-$default}
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= adhoc)); then
        choice=$((10#$choice))
        break
    fi
    echo "Enter a number from 1 to ${adhoc}."
done

identity=""
((choice < adhoc)) && identity=${names[$((choice - 1))]}
printf '# This Mac'"'"'s codesigning identity for `just app`; blank signs ad hoc.\nCODESIGN_IDENTITY="%s"\n' "$identity" >"$SIGNING_CONFIG"
echo "Saved config/signing.env: ${identity:-ad hoc}"
