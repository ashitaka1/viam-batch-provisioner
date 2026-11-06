# 38. Build the macOS app with SwiftPM and a bundling script

Date: 2026-10-31

## Status

Accepted

## Context

The macOS app needs a bundle: an Info.plist that registers the `viam-provisioner` URL scheme, a bundle ID, and a code signature for the Keychain. The rest of the Swift code is one SwiftPM package that builds with `swift build`.

## Decision

The app is the `ViamProvisioner` executable target in the package. `scripts/bundle-app.sh` (`just app`) builds it, assembles `build/Viam Provisioner.app` from `App/Info.plist`, signs it with `CODESIGN_IDENTITY` from the environment, else from the Mac's `config/signing.env` (which `just setup-wizard` asks for), else ad hoc with a warning, and registers it with Launch Services.

## Consequences

One build system and no project file to merge. Asset catalogs, entitlements, notarization and the SMAppService helper (#43) need build steps the script doesn't have yet; adopting an Xcode project is the path when those arrive. The login keychain grants an item to the signing identity, so team-signed builds keep access across rebuilds. An ad-hoc signature changes on every build, and the keychain asks again for access to keys saved by an earlier build. An Xcode project now (needs Xcode selected; `project.pbxproj` churn) and a generator such as XcodeGen or Tuist (another tool to install) were the alternatives.
