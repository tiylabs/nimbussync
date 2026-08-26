#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONFIG_FILE=${NIMBUSSYNC_CONFIG:-"$ROOT/.nimbussyncrc"}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
RUST_DIR="$ROOT/Rust"
OUT_DIR="$ROOT/Artifacts/CloudreveCore.xcframework"
HEADER_DIR="$ROOT/Rust/include"

rm -rf "$OUT_DIR"
mkdir -p "$ROOT/Artifacts"

targets=${RUST_TARGETS:-${NIMBUSSYNC_RUST_TARGETS:-aarch64-apple-darwin}}
libraries=""
for target in $targets; do
    cargo build --manifest-path "$RUST_DIR/Cargo.toml" --release -p cloudreve-ffi --target "$target"
    library="$RUST_DIR/target/$target/release/libcloudreve_ffi.a"
    if [ ! -f "$library" ]; then
        printf '%s\n' "missing Rust static library: $library" >&2
        exit 1
    fi
    libraries="$libraries $library"
done

set -- $libraries
if [ "$#" -eq 1 ]; then
    xcodebuild -create-xcframework -library "$1" -headers "$HEADER_DIR" -output "$OUT_DIR"
else
    lipo -create "$@" -output "$ROOT/Artifacts/libcloudreve_ffi_universal.a"
    xcodebuild -create-xcframework -library "$ROOT/Artifacts/libcloudreve_ffi_universal.a" -headers "$HEADER_DIR" -output "$OUT_DIR"
fi

shasum -a 256 "$OUT_DIR/Info.plist" > "$ROOT/Artifacts/CloudreveCore.xcframework.sha256"
