#!/usr/bin/env bash
# Build MeetingRecorder.app for Apple Silicon and zip it.
# Run this on a Mac with Xcode (GitHub Actions macos-latest). Not on the user's Mac.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/build"
DIST="$ROOT/dist"
STAGE="$DIST/MeetingRecorder-arm64"
APP_NAME="MeetingRecorder.app"

cd "$ROOT"

echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "macOS: $(sw_vers -productVersion)"

build() {
  xcodebuild \
    -project "$ROOT/MeetingRecorder.xcodeproj" \
    -scheme MeetingRecorder \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO \
    build
}

if ! build; then
  echo "Signed build failed; retrying without signing, then ad-hoc signing the product."
  xcodebuild \
    -project "$ROOT/MeetingRecorder.xcodeproj" \
    -scheme MeetingRecorder \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    clean build
fi

APP="$DERIVED/Build/Products/Release/$APP_NAME"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$DERIVED/Build/Products" -name "$APP_NAME" -type d | head -n 1)"
fi
if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  echo "Build finished but MeetingRecorder.app was not found." >&2
  exit 1
fi

# Ad-hoc signature. TCC (microphone + screen recording) will not stick on a fully unsigned binary.
# Each new signature changes the cdhash, so a freshly downloaded zip must be granted permissions again.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

BIN="$APP/Contents/MacOS/MeetingRecorder"
if command -v lipo >/dev/null 2>&1; then
  ARCH="$(lipo -archs "$BIN")"
  echo "Architectures: $ARCH"
  if [[ "$ARCH" != *"arm64"* ]]; then
    echo "Expected an arm64 binary." >&2
    exit 1
  fi
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME"
cp "$ROOT/packaging/请先读我.txt" "$STAGE/请先读我.txt"

ZIP="$DIST/MeetingRecorder-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"
(
  cd "$DIST"
  shasum -a 256 "MeetingRecorder-arm64.zip" > "MeetingRecorder-arm64.zip.sha256"
)
echo "Wrote $ZIP"
ls -lh "$ZIP"
