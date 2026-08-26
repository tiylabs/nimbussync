#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONFIG_FILE=${NIMBUSSYNC_CONFIG:-"$ROOT/.nimbussyncrc"}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
BUILD_ROOT=${BUILD_ROOT:-${NIMBUSSYNC_TEST_BUILD_ROOT:-"$ROOT/.build/ci-tests"}}

mkdir -p "$BUILD_ROOT/rust-home" "$BUILD_ROOT/swift-home" "$BUILD_ROOT/swift-modules" "$BUILD_ROOT/clang-modules" "$BUILD_ROOT/swift-build" "$BUILD_ROOT/swift-cache"

HOME="$BUILD_ROOT/rust-home" CARGO_HOME="$BUILD_ROOT/rust-home" cargo test --manifest-path "$ROOT/Rust/Cargo.toml" --workspace

HOME="$BUILD_ROOT/swift-home" \
SWIFT_MODULECACHE_PATH="$BUILD_ROOT/swift-modules" \
CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-modules" \
swift test \
    --disable-sandbox \
    --package-path "$ROOT" \
    --scratch-path "$BUILD_ROOT/swift-build" \
    --cache-path "$BUILD_ROOT/swift-cache"

printf '%s\n' 'Rust and Swift tests passed'
