#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GATE_ROOT="$ROOT/Artifacts/PhaseGates"
BUILD_ROOT="${CLOUDREVE_BUILD_ROOT:-/tmp/cloudreve-macos-gate}"
mkdir -p "$BUILD_ROOT" "$GATE_ROOT"

run_rust() {
    HOME="$BUILD_ROOT/rust-home" CARGO_HOME="$BUILD_ROOT/rust-home" cargo test --manifest-path "$ROOT/Rust/Cargo.toml" --workspace
}

run_swift() {
    mkdir -p "$BUILD_ROOT/swift-home" "$BUILD_ROOT/swift-modules" "$BUILD_ROOT/clang-modules" "$BUILD_ROOT/swift-build" "$BUILD_ROOT/swift-cache"
    HOME="$BUILD_ROOT/swift-home" SWIFT_MODULECACHE_PATH="$BUILD_ROOT/swift-modules" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-modules" swift test --disable-sandbox --package-path "$ROOT" --scratch-path "$BUILD_ROOT/swift-build" --cache-path "$BUILD_ROOT/swift-cache"
}

run_xcode() {
    mkdir -p "$BUILD_ROOT/xcode-home/Library/Logs/CoreSimulator" "$BUILD_ROOT/source-packages" "$BUILD_ROOT/package-cache" "$BUILD_ROOT/derived-data"
    HOME="$BUILD_ROOT/xcode-home" xcodebuild -project "$ROOT/CloudreveMac.xcodeproj" -scheme CloudreveMac -configuration Debug -derivedDataPath "$BUILD_ROOT/derived-data" -clonedSourcePackagesDirPath "$BUILD_ROOT/source-packages" -packageCachePath "$BUILD_ROOT/package-cache" -disablePackageRepositoryCache -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
}

secret_scan() {
    if rg -n --hidden --glob '!Artifacts/**' --glob '!.git/**' --glob '!*.lock' --glob '!Scripts/phase-gates/common.sh' "(Bearer[[:space:]]+[A-Za-z0-9_-]{12,}|refresh_token[\"=:[:space:]]+[\"']?[A-Za-z0-9_-]{12,}[\"']?|signedUrl|signed_url)" "$ROOT"; then
        printf '%s\n' "secret scan found a credential-like value" >&2
        return 1
    fi
}

release_scan() {
    if rg -n 'com\.apple\.developer\.fileprovider\.testing-mode|NSAllowsArbitraryLoads|allowInsecure|http://localhost|http://127\.0\.0\.1' "$ROOT/Config/Release.xcconfig" "$ROOT/Config/CloudreveMacRelease.entitlements" "$ROOT/Config/CloudreveFileProviderRelease.entitlements" "$ROOT/Config/CloudreveFileProviderUI.entitlements" "$ROOT/CloudreveMac.xcodeproj"; then
        printf '%s\n' "release scan found a forbidden entitlement or transport exception" >&2
        return 1
    fi
}

artifact_scan() {
    if rg -n --hidden --glob '!Artifacts/**' --glob '!.git/**' '(access_token|refresh_token|callback_secret|upload_urls|signed_url|signedUrl|Authorization)' "$ROOT/Artifacts" 2>/dev/null; then
        printf '%s\n' "artifact scan found credential-like output" >&2
        return 1
    fi
}
