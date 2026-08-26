#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=${VERSION:-0.1.0}
BUILD_ROOT=${BUILD_ROOT:-/tmp/nimbussync-release}
ARCHES=${ARCHES:-arm64}
mkdir -p "$BUILD_ROOT" "$ROOT/Dist"

export CLOUDREVE_BUILD_ROOT="$BUILD_ROOT/gate"
"$ROOT/Scripts/phase-gates/phase-4.sh" > "$BUILD_ROOT/phase-4.log" 2>&1

for arch in $ARCHES; do
    case "$arch" in
        arm64) destination='platform=macOS,arch=arm64' ;;
        x86_64) destination='platform=macOS,arch=x86_64' ;;
        *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
    esac
    HOME="$BUILD_ROOT/xcode-home" xcodebuild -project "$ROOT/NimbusSync.xcodeproj" -scheme NimbusSync -configuration Release -destination "$destination" -derivedDataPath "$BUILD_ROOT/derived-$arch" -clonedSourcePackagesDirPath "$BUILD_ROOT/packages-$arch" build CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-NO}
done

app="$BUILD_ROOT/derived-arm64/Build/Products/Release/NimbusSync.app"
if [ -d "$app" ]; then
    ditto "$app" "$ROOT/Dist/NimbusSync-$VERSION.app"
    ditto -c -k --sequesterRsrc --keepParent "$ROOT/Dist/NimbusSync-$VERSION.app" "$ROOT/Dist/NimbusSync-$VERSION.zip"
    shasum -a 256 "$ROOT/Dist/NimbusSync-$VERSION.zip" > "$ROOT/Dist/NimbusSync-$VERSION.zip.sha256"
fi

cat > "$ROOT/Dist/release-manifest.json" <<EOF
{
  "version": "$VERSION",
  "architectures": ["$ARCHES"],
  "signed": ${CODE_SIGNING_ALLOWED:-false},
  "notarized": false,
  "automatic_update": false,
  "source": "$(git -C "$ROOT" rev-parse HEAD)",
  "artifact": "Dist/NimbusSync-$VERSION.zip"
}
EOF
