#!/usr/bin/env bash
# Rebuilds lib/ from bridge/ and regenerates Swift protobufs. Needs scripts/setup.sh to have run once.
# Usage: scripts/build-bridge.sh [debug|release|all]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build A=$B/anki
export RUSTUP_HOME="$B/rustup" CARGO_HOME="$B/cargo" PATH="$B/cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=$(sed -n 's/^channel = "\(.*\)"/\1/p' "$A/rust-toolchain.toml") IPHONEOS_DEPLOYMENT_TARGET=17.0

mkdir -p "$A/ios_bridge"
rsync -a --delete "$ROOT/bridge/ios_bridge/" "$A/ios_bridge/"
grep -q '"ios_bridge"' "$A/Cargo.toml" || sed -i '' 's|^  "rslib",$|  "ios_bridge",\n  "rslib",|' "$A/Cargo.toml"
python3 -I "$ROOT/scripts/gen_methods.py" "$A"

mkdir -p "$ROOT/Sources/Generated"
PATH="$B/swift-protobuf/.build/release:$PATH" "$A/out/extracted/protoc/bin/protoc" -I"$A/proto" \
    --swift_out="$ROOT/Sources/Generated" --swift_opt=Visibility=Internal $(find "$A/proto/anki" -name '*.proto') 2>/dev/null

build() { # config cargo-flag target-dir-name
    for pair in aarch64-apple-ios:device aarch64-apple-ios-sim:simulator; do
        target=${pair%%:*} dir=${pair##*:}
        (cd "$A" && cargo build -p ios_bridge --target "$target" $2)
        mkdir -p "$ROOT/lib/$1/$dir"
        cp "$A/target/$target/$3/libios_bridge.a" "$ROOT/lib/$1/$dir/"
    done
}
mode=${1:-all}
[ "$mode" = release ] || build Debug "" debug
[ "$mode" = debug ] || build Release --release release
