#!/usr/bin/env bash
# Builds the macOS app and assembles build/Viam Provisioner.app, signs it
# and registers its URL scheme. Signs with CODESIGN_IDENTITY, else the team's
# Developer ID identity when the keychain holds it, else ad hoc. The keychain
# grants an ad-hoc build's Keychain items to that exact binary only, so each
# rebuild prompts for the login password.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Viam Provisioner.app"

cd "$ROOT"
swift build -c release --product ViamProvisioner
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/ViamProvisioner" "$APP/Contents/MacOS/"
cp App/Info.plist "$APP/Contents/Info.plist"

TEAM_IDENTITY="Developer ID Application: Bringing Fire, Inc. (HGCN675G7C)"
if [[ -z "${CODESIGN_IDENTITY:-}" ]] && security find-identity -v -p codesigning | grep -qF "\"$TEAM_IDENTITY\""; then
    CODESIGN_IDENTITY=$TEAM_IDENTITY
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "$APP"
