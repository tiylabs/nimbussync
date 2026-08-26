#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONFIG_FILE=${NIMBUSSYNC_CONFIG:-"$ROOT/.nimbussyncrc"}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
VERSION=${VERSION:-${NIMBUSSYNC_VERSION:-0.1.0}}
BUILD_ROOT=${BUILD_ROOT:-${NIMBUSSYNC_RELEASE_BUILD_ROOT:-/tmp/nimbussync-release}}
ARCHES=${ARCHES:-${NIMBUSSYNC_RELEASE_ARCHES:-arm64}}
mkdir -p "$BUILD_ROOT" "$ROOT/Dist"

signed=false
SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-${NIMBUSSYNC_CODE_SIGNING_ALLOWED:-NO}}
case "$SIGNING_ALLOWED" in
    YES|yes|true|TRUE|1) signed=true ;;
esac

BUILD_ROOT="$BUILD_ROOT/tests" "$ROOT/Scripts/ci/test.sh" > "$BUILD_ROOT/test.log" 2>&1
"$ROOT/Scripts/ci/verify.sh" > "$BUILD_ROOT/verify.log" 2>&1

for arch in $ARCHES; do
    case "$arch" in
        arm64) destination='platform=macOS,arch=arm64' ;;
        x86_64) destination='platform=macOS,arch=x86_64' ;;
        *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
    esac
    HOME="$BUILD_ROOT/xcode-home" xcodebuild -project "$ROOT/NimbusSync.xcodeproj" -scheme NimbusSync -configuration Release -destination "$destination" -derivedDataPath "$BUILD_ROOT/derived-$arch" -clonedSourcePackagesDirPath "$BUILD_ROOT/packages-$arch" build CODE_SIGNING_ALLOWED="$SIGNING_ALLOWED"
done

app="$BUILD_ROOT/derived-arm64/Build/Products/Release/NimbusSync.app"
if [ -d "$app" ]; then
    artifact="$ROOT/Dist/NimbusSync.app"
    ditto "$app" "$artifact"
    if [ "$signed" = true ]; then
        codesign --verify --deep --strict --verbose=2 "$artifact"
    fi
    ditto -c -k --sequesterRsrc --keepParent "$artifact" "$ROOT/Dist/NimbusSync-$VERSION.zip"
    shasum -a 256 "$ROOT/Dist/NimbusSync-$VERSION.zip" > "$ROOT/Dist/NimbusSync-$VERSION.zip.sha256"
fi

cat > "$ROOT/Dist/release-manifest.json" <<EOF
{
  "version": "$VERSION",
  "architectures": ["$ARCHES"],
  "signed": $signed,
  "notarized": false,
  "automatic_update": false,
  "source": "$(git -C "$ROOT" rev-parse HEAD)",
  "artifact": "Dist/NimbusSync-$VERSION.zip"
}
EOF
