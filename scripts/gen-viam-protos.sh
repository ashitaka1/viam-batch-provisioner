#!/usr/bin/env bash
# Generates Swift types for Viam's AppService and AuthService into Sources/ViamAPI/Generated.
# Bump a pin below and rerun to pick up API changes.
set -euo pipefail

API_SHA=c3bf2d45b7a95c10c945f6201a915095d06ef3b9        # viamrobotics/api
GOUTILS_SHA=be5cec0a62233603c5163be8250f099cc4e4c35a    # viamrobotics/goutils
GOOGLEAPIS_SHA=ff8fd20f3840386e12f4f69750eff6dc99f6e1b7 # googleapis/googleapis

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Sources/ViamAPI/Generated"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v protoc >/dev/null || { echo "protoc not found: brew install protobuf" >&2; exit 1; }

fetch() { # repo sha dir
    git -C "$WORK" init -q "$3"
    git -C "$WORK/$3" fetch -q --depth 1 "https://github.com/$1" "$2"
    git -C "$WORK/$3" checkout -q FETCH_HEAD
}
fetch viamrobotics/api "$API_SHA" api
fetch viamrobotics/goutils "$GOUTILS_SHA" goutils

mkdir -p "$WORK/include/proto/rpc/v1"
cp "$WORK/goutils/proto/rpc/v1/auth.proto" "$WORK/include/proto/rpc/v1/"

INCLUDES=(-I "$WORK/api/proto/viam" -I "$WORK/api/proto" -I "$WORK/include")

# app/v1/app.proto and everything it imports, except protobuf's well-known types.
seen=" "
queue=("app/v1/app.proto" "proto/rpc/v1/auth.proto")
files=()
resolve() {
    if [[ $1 == google/* && ! -f "$WORK/include/$1" ]]; then
        mkdir -p "$WORK/include/$(dirname "$1")"
        curl -fsSL "https://raw.githubusercontent.com/googleapis/googleapis/$GOOGLEAPIS_SHA/$1" -o "$WORK/include/$1"
    fi
    for dir in "$WORK/api/proto/viam" "$WORK/api/proto" "$WORK/include"; do
        [[ -f "$dir/$1" ]] && { echo "$dir/$1"; return; }
    done
    echo "missing import: $1" >&2; exit 1
}
while ((${#queue[@]})); do
    f=${queue[0]}; queue=("${queue[@]:1}")
    [[ $seen == *" $f "* || $f == google/protobuf/* ]] && continue
    seen+="$f "
    files+=("$f")
    while read -r imp; do queue+=("$imp"); done < <(sed -n 's/^import "\(.*\)";/\1/p' "$(resolve "$f")")
done

(cd "$ROOT" && swift build -c release --product protoc-gen-swift >/dev/null)
PLUGIN="$ROOT/.build/release/protoc-gen-swift"

rm -rf "$OUT"
mkdir -p "$OUT"
protoc "${INCLUDES[@]}" --plugin=protoc-gen-swift="$PLUGIN" \
    --swift_out="$OUT" --swift_opt=Visibility=Public --swift_opt=FileNaming=PathToUnderscores \
    "${files[@]}"
echo "generated ${#files[@]} files into ${OUT#"$ROOT"/}"
