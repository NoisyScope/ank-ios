#!/usr/bin/env bash
# Regenerates lib/ and web/ from Anki's source. Only needed to change the Anki version or the Rust bridge.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build
TAG=${ANKI_TAG:-26.09.4}
SWIFT_PROTOBUF=1.39.0 # keep in step with the Xcode project
N2_REV=53ec691df749277104d1d4201a344fe4243d6d0a # from tools/install-n2
# Anki's ./ninja does not quote its paths.
case "$B" in *" "*) echo "This project's path must not contain spaces: $B" >&2; exit 1 ;; esac
mkdir -p "$B"

A=$B/anki
[ -d "$A" ] || git clone --quiet --depth 1 --branch "$TAG" https://github.com/ankitects/anki.git "$A"
git -C "$A" submodule update --init --depth 1 ftl/core-repo ftl/qt-repo

RUST=$(sed -n 's/^channel = "\(.*\)"/\1/p' "$A/rust-toolchain.toml")

export RUSTUP_HOME="$B/rustup" CARGO_HOME="$B/cargo" PATH="$B/cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
if [ ! -x "$B/cargo/bin/rustup" ]; then
    U=https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init
    curl -fsSL "$U" -o "$B/rustup-init"
    [ "$(curl -fsSL "$U.sha256" | awk '{print $1}')" = "$(shasum -a 256 "$B/rustup-init" | awk '{print $1}')" ]
    chmod +x "$B/rustup-init"
    "$B/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
fi
rustup toolchain install "$RUST" --profile minimal -t aarch64-apple-ios -t aarch64-apple-ios-sim
export RUSTUP_TOOLCHAIN=$RUST
[ -x "$B/cargo/bin/just" ] || (cd "$B" && cargo install --quiet --locked just)
[ -x "$B/cargo/bin/n2" ] || (cd "$B" && cargo install --quiet --git https://github.com/evmar/n2.git --rev "$N2_REV")

(cd "$A" && just build) # builds the web assets and sets up protoc

if [ ! -x "$B/swift-protobuf/.build/release/protoc-gen-swift" ]; then
    [ -d "$B/swift-protobuf" ] || git clone --quiet --depth 1 --branch "$SWIFT_PROTOBUF" https://github.com/apple/swift-protobuf.git "$B/swift-protobuf"
    (cd "$B/swift-protobuf" && swift build -c release --product protoc-gen-swift)
fi
"$ROOT/scripts/build-bridge.sh" all

mkdir -p "$ROOT/web"
rsync -aL --delete --exclude '*.map' "$A/out/qt/_aqt/data/web/" "$ROOT/web/"
echo "Done. Open AnkiStudy.xcodeproj in Xcode."
