#!/usr/bin/env bash
# Build a release zip + (re)generate appcast.xml + optionally publish it.
#
#   VERSION=0.2.0 BUILD=42 ./scripts/release.sh
#   VERSION=0.2.0 GITHUB_REPOSITORY=owner/token-terrier GITHUB_RELEASE=1 ./scripts/release.sh
#
# Requires:
#  - Sparkle private key in infra/sparkle-private-key.backup
#  - gh auth when GITHUB_RELEASE=1
#  - SSH/rsync access when UPLOAD_TARGET is set
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:?set VERSION (e.g. VERSION=0.2.0)}"
BUILD="${BUILD:-$(date +%s)}"
APP_NAME="TokenTerrier"
RELEASES_DIR="$ROOT/releases"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_RELEASE="${GITHUB_RELEASE:-0}"
TAG_NAME="${TAG_NAME:-v$VERSION}"

if [[ -n "$GITHUB_REPOSITORY" ]]; then
    FEED_URL="${FEED_URL:-https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml}"
    DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/}"
    # The "latest/download" URL only exposes assets from the latest release.
    # Keep the GitHub-hosted appcast to one item so older items don't point at
    # assets that are no longer attached to /latest.
    MAXIMUM_VERSIONS="${MAXIMUM_VERSIONS:-1}"
else
    FEED_URL="${FEED_URL:-}"
    DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
    MAXIMUM_VERSIONS="${MAXIMUM_VERSIONS:-3}"
fi
MAXIMUM_DELTAS="${MAXIMUM_DELTAS:-5}"
UPLOAD_TARGET="${UPLOAD_TARGET:-}"

if [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
    echo "✗ set GITHUB_REPOSITORY or DOWNLOAD_URL_PREFIX" >&2
    exit 1
fi

# 1. Build the .app bundle pinned to this version/build.
echo "▶ make-app.sh VERSION=$VERSION BUILD=$BUILD"
VERSION="$VERSION" BUILD="$BUILD" FEED_URL="$FEED_URL" GITHUB_REPOSITORY="$GITHUB_REPOSITORY" "$ROOT/scripts/make-app.sh"

# 2. Zip the .app — use `ditto -c -k --keepParent` so macOS preserves the
#    framework's symlink layout inside the zip (regular `zip` flattens them).
mkdir -p "$RELEASES_DIR"
rm -f "$ZIP_PATH"
echo "▶ zipping $APP_NAME.app -> $ZIP_NAME"
ditto -c -k --keepParent "$ROOT/build/$APP_NAME.app" "$ZIP_PATH"

# 3. Regenerate appcast.xml — generate_appcast scans the releases dir, signs
#    every zip with the Sparkle private key, and emits the feed.
#    We pass the key by file so the tool doesn't need an interactive Keychain
#    prompt (which fails from non-Terminal sessions like CI or Claude Code).
KEY_FILE="$ROOT/infra/sparkle-private-key.backup"
if [[ ! -f "$KEY_FILE" ]]; then
    echo "✗ private key file missing at $KEY_FILE" >&2
    echo "  Run: $SPARKLE_BIN/generate_keys -x $KEY_FILE  (or restore from backup)" >&2
    exit 1
fi

echo "▶ generate_appcast (signs zips, writes appcast.xml)"
"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-versions "$MAXIMUM_VERSIONS" \
    --maximum-deltas "$MAXIMUM_DELTAS" \
    "$RELEASES_DIR"

ls -la "$RELEASES_DIR"/*.zip "$RELEASES_DIR/appcast.xml"

# 4. Publish assets to GitHub Releases when requested. The appcast uses
#    /releases/latest/download URLs, so the latest zip, appcast, and generated
#    deltas for this build must all be attached to the latest release.
if [[ "$GITHUB_RELEASE" == "1" ]]; then
    if [[ -z "$GITHUB_REPOSITORY" ]]; then
        echo "✗ GITHUB_RELEASE=1 requires GITHUB_REPOSITORY=owner/repo" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "✗ gh CLI is required for GITHUB_RELEASE=1" >&2
        exit 1
    fi

    shopt -s nullglob
    DELTAS=("$RELEASES_DIR/${APP_NAME}${BUILD}-"*.delta)
    shopt -u nullglob
    ASSETS=("$ZIP_PATH" "$RELEASES_DIR/appcast.xml" "${DELTAS[@]}")

    if gh release view "$TAG_NAME" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        echo "▶ gh release upload $TAG_NAME (${#ASSETS[@]} assets)"
        gh release upload "$TAG_NAME" "${ASSETS[@]}" --repo "$GITHUB_REPOSITORY" --clobber
    else
        echo "▶ gh release create $TAG_NAME (${#ASSETS[@]} assets)"
        gh release create "$TAG_NAME" "${ASSETS[@]}" \
            --repo "$GITHUB_REPOSITORY" \
            --title "$APP_NAME $VERSION" \
            --notes "$APP_NAME $VERSION"
    fi
fi

# 5. Optional rsync upload for self-hosted appcasts or one-time migration
#    bridges. Skip with NO_UPLOAD=1.
if [[ "${NO_UPLOAD:-0}" != "1" && -n "$UPLOAD_TARGET" ]]; then
    echo "▶ rsync -> $UPLOAD_TARGET"
    rsync -avz \
        --include '*.zip' --include '*.delta' --include 'appcast.xml' \
        --exclude 'old_updates/**' --exclude '*' \
        "$RELEASES_DIR/" "$UPLOAD_TARGET"
fi

echo "✔ released $APP_NAME $VERSION (build $BUILD)"
