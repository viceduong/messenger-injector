#!/bin/bash
# build_all.sh — Local build script (run on a Mac with Xcode)
# Builds both the dylib and the helper app IPA.
#
# Usage:
#   chmod +x scripts/build_all.sh
#   ./scripts/build_all.sh
#
# Output:
#   dist/libMessengerInjector.dylib
#   dist/MIHelper_1.0.ipa

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"

mkdir -p "$DIST_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "=== Messenger Injector Build ==="
echo "SDK: $SDK"
echo "Xcode: $(xcodebuild -version | head -1)"
echo ""

# -------------------------------------------------------
# 1. Build dylib
# -------------------------------------------------------
echo ">>> Building dylib..."
xcrun clang -dynamiclib \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -framework Foundation \
  -framework UIKit \
  -ObjC \
  -fobjc-arc \
  -O2 \
  -o "$DIST_DIR/libMessengerInjector.dylib" \
  "$PROJECT_DIR/dylib/MessengerInjector.m"

codesign -f -s - "$DIST_DIR/libMessengerInjector.dylib"
echo "    ✓ dylib built and signed"
file "$DIST_DIR/libMessengerInjector.dylib"

# -------------------------------------------------------
# 2. Build helper app binary
# -------------------------------------------------------
echo ""
echo ">>> Building helper app..."
xcrun clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -framework Foundation \
  -framework UIKit \
  -ObjC \
  -fobjc-arc \
  -O2 \
  -o "$PROJECT_DIR/helper-app/MIHelper" \
  "$PROJECT_DIR/helper-app/MIHelper.m"

echo "    ✓ helper binary built"

# -------------------------------------------------------
# 3. Create IPA
# -------------------------------------------------------
echo ""
echo ">>> Creating IPA..."
APP_DIR="$DIST_DIR/Payload/MIHelper.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

cp "$PROJECT_DIR/helper-app/MIHelper" "$APP_DIR/"
cp "$PROJECT_DIR/helper-app/Info.plist" "$APP_DIR/"

codesign -f -s - "$APP_DIR"

cd "$DIST_DIR"
rm -f MIHelper_1.0.ipa
zip -r MIHelper_1.0.ipa Payload/
cd "$PROJECT_DIR"

echo "    ✓ IPA created"

# -------------------------------------------------------
# 4. Verify
# -------------------------------------------------------
echo ""
echo "=== Verification ==="
echo ""
echo "--- Dylib ---"
file "$DIST_DIR/libMessengerInjector.dylib"
codesign -v "$DIST_DIR/libMessengerInjector.dylib" && echo "    ✓ dylib signature valid"
otool -l "$DIST_DIR/libMessengerInjector.dylib" | grep -A3 "LC_BUILD_VERSION" || true
echo ""
echo "--- IPA ---"
ls -la "$DIST_DIR/MIHelper_1.0.ipa"
unzip -l "$DIST_DIR/MIHelper_1.0.ipa"
echo ""
echo "=== Done ==="
echo ""
echo "Artifacts in $DIST_DIR/"
echo "  libMessengerInjector.dylib  → inject into Messenger via TrollFools"
echo "  MIHelper_1.0.ipa            → install via TrollStore"
echo ""
echo "Next steps:"
echo "  1. AirDrop/transfer both files to iPhone"
echo "  2. Install MIHelper_1.0.ipa via TrollStore"
echo "  3. Open TrollFools → Messenger → Inject → select libMessengerInjector.dylib"
echo "  4. Force-quit and reopen Messenger"
echo "  5. Open MI Helper → enter thread ID + message → Send"