# Sourced by scripts/bundle-app.sh. app_fingerprint ROOT [SETTING...] prints a hash of everything
# the app bundle is built from: the package's sources and manifests, App/, the OpenAPI spec and
# the bundling script, plus each SETTING (the signing identity, the toolchain version). Symlinks
# are followed, so the specs that Sources/*/openapi.yaml point to count. Hidden and backup files
# are left out; SwiftPM ignores them.
app_fingerprint() {
    local root=$1
    shift
    (
        cd "$root" || exit 1
        printf 'setting=%s\n' "$@"
        local inputs=() input
        for input in Sources App openapi Package.swift Package.resolved scripts/bundle-app.sh; do
            [[ -e $input ]] && inputs+=("$input")
        done
        find -L "${inputs[@]}" -type f ! -name '.*' ! -name '*~' ! -name '*.orig' -print0 \
            | LC_ALL=C sort -z | xargs -0 shasum -a 256
    ) | shasum -a 256 | cut -d' ' -f1
}

# Prints the SHA-1 of the keychain certificate behind a codesigning identity, given by name or
# hash, so a renewed certificate under the same name changes the fingerprint. Ad hoc prints nothing.
signing_certificate() {
    local identity=$1
    [[ -z $identity || $identity == - ]] && return 0
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$identity" '$2 == id || index($0, "\"" id "\"") { print $2; exit }'
}
