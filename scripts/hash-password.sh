#!/usr/bin/env bash
# Print a SHA-512 ($6$) crypt hash of the password on stdin (cloud-init /
# autoinstall). macOS's system openssl is LibreSSL, which lacks `passwd -6`,
# so a real openssl or mkpasswd must be on PATH; fail loudly otherwise.
# stdin keeps the password off the process command line.
set -euo pipefail

password="$(cat)"
[[ -n "$password" ]] || { echo "hash-password: empty password on stdin" >&2; exit 1; }

if command -v mkpasswd &>/dev/null; then
    printf '%s' "$password" | mkpasswd -m sha-512 --stdin
    exit 0
fi

if command -v openssl &>/dev/null && openssl passwd -6 -salt probe probe &>/dev/null; then
    printf '%s' "$password" | openssl passwd -6 -stdin
    exit 0
fi

echo "hash-password: no SHA-512-capable password hasher on PATH." >&2
echo "  macOS: brew install openssl, and put 'eval \"\$(brew shellenv)\"' in ~/.zprofile" >&2
echo "         so /opt/homebrew/bin precedes /usr/bin (system LibreSSL can't do SHA-512)." >&2
echo "  Linux: apt install whois  (provides mkpasswd)" >&2
exit 1
