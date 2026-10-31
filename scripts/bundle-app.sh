#!/usr/bin/env bash
# Builds the macOS app and assembles build/Viam Provisioner.app, signs it
# (ad hoc unless CODESIGN_IDENTITY is set), and registers its URL scheme.
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

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "$APP"
