#!/usr/bin/env bash
# Builds the macOS app and assembles build/Viam Provisioner.app with the
# ProvisionerHelper launch daemon inside, signs it and registers its URL scheme.
# Also builds and signs build/provisioner-helperctl, which drives the helper. Signs with CODESIGN_IDENTITY, else the team's
# Developer ID identity when the keychain holds it, else ad hoc. The keychain
# grants an ad-hoc build's Keychain items to that exact binary only, so each
# rebuild prompts for the login password.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Viam Provisioner.app"

cd "$ROOT"
for product in ViamProvisioner ProvisionerHelper provisioner-helperctl; do
    swift build -c release --product "$product"
done
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/ViamProvisioner" "$BIN/ProvisionerHelper" "$APP/Contents/MacOS/"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/LaunchDaemons/*.plist "$APP/Contents/Library/LaunchDaemons/"
cp "$BIN/provisioner-helperctl" "$ROOT/build/provisioner-helperctl"

TEAM_IDENTITY="Developer ID Application: Bringing Fire, Inc. (HGCN675G7C)"
if [[ -z "${CODESIGN_IDENTITY:-}" ]] && security find-identity -v -p codesigning | grep -qF "\"$TEAM_IDENTITY\""; then
    CODESIGN_IDENTITY=$TEAM_IDENTITY
fi
# The helper accepts peers by team, or, ad hoc, by these identifiers (PeerRequirement).
SIGN=(codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}")
"${SIGN[@]}" --identifier com.bringingfire.viam-provisioner.helper "$APP/Contents/MacOS/ProvisionerHelper"
"${SIGN[@]}" --identifier com.bringingfire.viam-provisioner.helperctl "$ROOT/build/provisioner-helperctl"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "$APP"
