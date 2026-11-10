#!/usr/bin/env bash
# Builds the macOS app and assembles build/Viam Provisioner.app with the
# ProvisionerNetboot launch daemon inside, signs it and registers its URL scheme.
# Also builds and signs build/provisioner-netbootctl, which drives the netboot daemon. Signs with
# CODESIGN_IDENTITY from the environment, else from config/signing.env, else ad hoc.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Viam Provisioner.app"

# The identity belongs to this Mac, not to the active provisioning environment.
SIGNING_CONFIG="$ROOT/config/signing.env"
if [[ -z "${CODESIGN_IDENTITY:-}" && -f "$SIGNING_CONFIG" ]]; then
    CODESIGN_IDENTITY=$(sed -n -e 's/^\(export \)\{0,1\}CODESIGN_IDENTITY=//p' "$SIGNING_CONFIG" | tr -d '"'"'" | tail -1)
fi
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "Signing with: $CODESIGN_IDENTITY" >&2
else
    echo "WARNING: no CODESIGN_IDENTITY in the environment or config/signing.env; signing ad hoc." >&2
    echo "  An ad-hoc signature changes with every build, so the Keychain asks for the login" >&2
    echo "  password again for each environment's secrets. 'just set-signing-identity' records one." >&2
fi

cd "$ROOT"
for product in ViamProvisioner ProvisionerNetboot provisioner-netbootctl; do
    swift build -c release --product "$product"
done
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/ViamProvisioner" "$BIN/ProvisionerNetboot" "$APP/Contents/MacOS/"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/LaunchDaemons/*.plist "$APP/Contents/Library/LaunchDaemons/"
cp "$BIN/provisioner-netbootctl" "$ROOT/build/provisioner-netbootctl"

# The netboot daemon accepts peers by team, or, ad hoc, by these identifiers (PeerRequirement).
SIGN=(codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}")
"${SIGN[@]}" --identifier com.bringingfire.viam-provisioner.netboot "$APP/Contents/MacOS/ProvisionerNetboot"
"${SIGN[@]}" --identifier com.bringingfire.viam-provisioner.netbootctl "$ROOT/build/provisioner-netbootctl"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "$APP"
