#!/usr/bin/env bash
# Records this Mac's codesigning identity for `just app` in config/signing.env.
# Lists the login keychain's identities, so run it from a logged-in terminal.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_CONFIG="${REPO_ROOT}/config/signing.env"

current=""
if [[ -f "$SIGNING_CONFIG" ]]; then
    current=$(sed -n 's/^CODESIGN_IDENTITY=//p' "$SIGNING_CONFIG" | tr -d '"' | tail -1)
fi
echo "Code signing for the macOS app ('just app'): ${current:-ad hoc}"
echo "  Builds signed with an identity keep their Keychain access across rebuilds."
echo "  Ad hoc works, but every rebuild asks for the login password again."

identities=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')
default=${current:-$(grep -m1 '^Developer ID Application:' <<<"$identities" || true)}
if [[ -n "$identities" ]]; then
    echo "  Identities in your keychain:"
    while IFS= read -r identity; do echo "    ${identity}"; done <<<"$identities"
else
    echo "  No signing identities found in this keychain (a locked keychain lists none)."
fi

read -p "  Signing identity (blank for ${default:-ad hoc}, '-' for ad hoc): " choice
choice="${choice:-$default}"
[[ "$choice" == "-" ]] && choice=""
printf '# This Mac'"'"'s codesigning identity for `just app`; blank signs ad hoc.\nCODESIGN_IDENTITY="%s"\n' "$choice" >"$SIGNING_CONFIG"
echo "Saved: config/signing.env (${choice:-ad hoc})"
