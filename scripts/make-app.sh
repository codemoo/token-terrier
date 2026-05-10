#!/usr/bin/env bash
# Wrap the SwiftPM `token-run-menubar` executable into a proper TokenTerrier.app
# bundle so Sparkle can update it. Sparkle replaces the .app at runtime, so the
# bundle layout (Frameworks/Sparkle.framework + signed Updater.app + XPC
# services) has to be exactly right.
#
#   VERSION=0.4.0 BUILD=4 ./scripts/make-app.sh
#   VERSION=0.4.0 BUILD=4 GITHUB_REPOSITORY=owner/token-terrier ./scripts/make-app.sh
#
# Outputs: build/TokenTerrier.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
EXE_NAME="token-run-menubar"
APP_NAME="TokenTerrier"
DISPLAY_NAME="Token Terrier"
# Bundle identifier must stay stable for existing installs. Set BUNDLE_ID when
# building updates for a previously distributed bundle.
BUNDLE_ID="${BUNDLE_ID:-app.token-terrier.menubar}"
if [[ -z "${FEED_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    FEED_URL="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml"
else
    FEED_URL="${FEED_URL:-}"
fi
PUBKEY="$(tr -d '\n' < "$ROOT/infra/sparkle-public-key.txt")"

OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"
RES_BUNDLE="$ROOT/.build/release/token-run_token-run-menubar.bundle"

echo "▶ swift build -c release --product $EXE_NAME"
rm -rf "$RES_BUNDLE"
swift build -c release --product "$EXE_NAME"

# Locate Sparkle.framework — Swift 6 / SPM 'artifacts' path.
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FW" ]]; then
  echo "✗ Sparkle.framework not found at $SPARKLE_FW" >&2
  exit 1
fi

echo "▶ wiping $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

echo "▶ installing executable"
cp ".build/release/$EXE_NAME" "$APP/Contents/MacOS/$APP_NAME"

echo "▶ embedding Sparkle.framework (with all sub-bundles)"
# `ditto` preserves the framework's symlink layout (Versions/A → Current → ...)
# which `cp -RL` would flatten and break.
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

echo "▶ embedding app icon"
ICNS_PATH="$ROOT/build/AppIcon.icns"
"$ROOT/scripts/build-icon.sh"
cp "$ICNS_PATH" "$APP/Contents/Resources/AppIcon.icns"

echo "▶ embedding SwiftPM resource bundles (Bedlington Terrier sprite frames, etc.)"
# SwiftPM emits each `resources:` declaration as a .bundle alongside the
# executable. `Bundle.module` looks for it next to the binary, so copy the
# whole bundle into Contents/Resources/.
if [[ -d "$RES_BUNDLE" ]]; then
    ditto "$RES_BUNDLE" "$APP/Contents/Resources/$(basename "$RES_BUNDLE")"
else
    echo "✗ resource bundle missing — was the release build run?" >&2
    exit 1
fi

echo "▶ writing Info.plist (version $VERSION, build $BUILD)"
FEED_PLIST=""
if [[ -n "$FEED_URL" ]]; then
    FEED_PLIST="    <key>SUFeedURL</key>
    <string>$FEED_URL</string>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Hwanmoo Yong</string>
$FEED_PLIST
    <key>SUPublicEDKey</key>
    <string>$PUBKEY</string>
    <key>SUEnableInstallerLauncherService</key>
    <false/>
    <!--
        Development and self-hosted deployments may use loopback, LAN, or a
        private HTTPS endpoint for the daemon/appcast. NSAllowsArbitraryLoads
        is broad; keep it only while this app is personal/internal.
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "▶ ad-hoc signing (good enough for personal/internal use)"
# Sparkle requires every nested helper to be signed too. --deep handles them.
codesign --force --deep --sign - --timestamp=none \
    "$APP/Contents/Frameworks/Sparkle.framework"

ENT_PLIST="$(mktemp -t tokenrun-entitlements).plist"
cat > "$ENT_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
EOF
codesign --force --options runtime --sign - --timestamp=none \
    --entitlements "$ENT_PLIST" "$APP"
rm -f "$ENT_PLIST"

echo "✔ built $APP (version $VERSION build $BUILD)"
codesign --display --verbose=2 "$APP" 2>&1 | head -8
