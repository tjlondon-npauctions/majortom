#!/bin/zsh
# Release build -> build/MajorTom.app (ad-hoc signed, universal arm64 + x86_64). The `majortom` CLI ships inside
# the bundle at Contents/Helpers/majortom; build/majortom is a symlink to it.
# OUT_DIR=<folder> builds there instead of build/ (e.g. while a copy in build/ is running).
# ARCHS="arm64" builds for one architecture only (faster while developing). Default: "arm64 x86_64".
# The version comes from the VERSION file (single source of truth); the minimum macOS from Package.swift
# (read back from the built binary, so Info.plist can't drift from it).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT"
APP="$OUT/MajorTom.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "VERSION must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2
  exit 1
fi
ARCHS=(${=ARCHS:-arm64 x86_64})
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
# Notifications, privacy grants and the login item are keyed to the bundle id; override it if you like.
BUNDLE_ID="${BUNDLE_ID:-uk.co.tom-jordan.majortom}"

swift build -c release $ARCH_FLAGS --product MajorTomApp
swift build -c release $ARCH_FLAGS --product majortom
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

# Minimum macOS as compiled in (Package.swift `platforms`), e.g. 15.0.
MIN_MACOS="$(vtool -show-build "$BIN_DIR/MajorTomApp" | awk '/minos/ { print $2; exit }')"
if [[ -z "$MIN_MACOS" ]]; then echo "Couldn't read the minimum macOS from the binary" >&2; exit 1; fi

rm -rf "$APP"
# MacOS/MajorTom and a MacOS/majortom would collide on a case-insensitive volume, so the CLI goes in Helpers.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/MajorTomApp" "$APP/Contents/MacOS/MajorTom"
cp "$BIN_DIR/majortom" "$APP/Contents/Helpers/majortom"
rm -f "$OUT/majortom"
ln -s "MajorTom.app/Contents/Helpers/majortom" "$OUT/majortom"

# App icon: drawn by scripts/make-icon.swift (CoreGraphics) -> iconset -> .icns. design/AppIcon.icns is the
# committed output; the 512 px previews of all candidates live in design/icon-candidates/.
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/design/AppIcon.icns"
rm -rf "$ICONSET"
cp "$ROOT/design/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Install native localizations in the main bundle for SwiftUI, AppKit and per-app language selection.
cp -R "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Major Tom</string>
  <key>CFBundleDisplayName</key><string>Major Tom</string>
  <key>CFBundleExecutable</key><string>MajorTom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signatures only (no Developer ID, not notarised): nested code first, then the bundle.
codesign --force --sign - --timestamp=none --identifier "${BUNDLE_ID}.cli" "$APP/Contents/Helpers/majortom"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP (version $VERSION, macOS $MIN_MACOS+, $(lipo -archs "$APP/Contents/MacOS/MajorTom"))"
