#!/bin/sh
# Fully remove every Token Terrier menu-bar app variant + stale state, then
# reinstall the latest release cleanly. Fixes the "menu bar icon missing" /
# "update errors" caused by the app's rename history (TokenCat -> TokenBedl
# -> TokenRun -> TokenTerrier) leaving two bundle-id families and duplicate
# LaunchServices registrations behind.
#
# Only touches the menu-bar VIEWER app. Does NOT touch the server daemon or
# ~/.config/token-usage (bearer tokens / claude-swap accounts file), so remote
# monitoring keeps working.
#
#   sh scripts/clean-reinstall.sh          # interactive (asks before removing)
#   sh scripts/clean-reinstall.sh -y       # no prompt
#   REPO=owner/repo sh scripts/clean-reinstall.sh
set -eu

REPO="${REPO:-codemoo/token-terrier}"
NAMES="TokenTerrier TokenCat TokenBedl TokenRun"
# Bundle-id families accumulated across the app's renames.
IDS="app.token-terrier.menubar kr.hwanmoo.token-run token-run-menubar"

if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
	printf 'This removes all Token Terrier app bundles + their prefs/caches on this Mac,\n'
	printf 'then installs the latest release. The server daemon is NOT affected.\n'
	printf 'Continue? [y/N] '
	read -r ans
	case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 0 ;; esac
fi

echo "▶ 1) quit every running Token* instance"
for n in $NAMES; do
	osascript -e "quit app \"$n\"" 2>/dev/null || true
	pkill -f "$n.app/Contents/MacOS/" 2>/dev/null || true
done
pkill -f "Sparkle.*Updater" 2>/dev/null || true
pkill -f "org.sparkle-project.Sparkle" 2>/dev/null || true
sleep 1

echo "▶ 2) remove app bundles from /Applications and ~/Applications"
for dir in /Applications "$HOME/Applications"; do
	for n in $NAMES; do
		[ -e "$dir/$n.app" ] && echo "   rm $dir/$n.app" && rm -rf "$dir/$n.app"
	done
done

echo "▶ 3) purge prefs / caches / saved state for all bundle-id families"
for id in $IDS; do
	defaults delete "$id" 2>/dev/null || true
	rm -f  "$HOME/Library/Preferences/$id.plist"
	rm -rf "$HOME/Library/Caches/$id"
	rm -rf "$HOME/Library/Saved Application State/$id.savedState"
	rm -rf "$HOME/Library/Application Support/$id"
	rm -rf "$HOME/Library/HTTPStorages/$id" "$HOME/Library/HTTPStorages/$id.binarycookies"
done
killall cfprefsd 2>/dev/null || true

echo "▶ 4) reset LaunchServices registration (clears duplicate/stale entries)"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	-kill -r -domain local -domain user 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "▶ 5) download + install the latest release"
APPCAST="https://github.com/${REPO}/releases/latest/download/appcast.xml"
ZIP_URL="$(curl -sL "$APPCAST" | grep -oE "https://[^\"]*TokenTerrier-[0-9.]*\.zip" | head -1)"
if [ -z "$ZIP_URL" ]; then
	echo "✗ could not find the latest zip in $APPCAST" >&2
	exit 1
fi
TMP="$(mktemp -d)"
echo "   $ZIP_URL"
curl -sL -o "$TMP/TokenTerrier.zip" "$ZIP_URL"
ditto -x -k "$TMP/TokenTerrier.zip" "$TMP"
# Releases are ad-hoc signed (not notarized) -> strip Gatekeeper quarantine so
# it opens without "Apple cannot check it for malicious software".
xattr -dr com.apple.quarantine "$TMP/TokenTerrier.app" 2>/dev/null || true
rm -rf /Applications/TokenTerrier.app
ditto "$TMP/TokenTerrier.app" /Applications/TokenTerrier.app
rm -rf "$TMP"
open /Applications/TokenTerrier.app

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/TokenTerrier.app/Contents/Info.plist 2>/dev/null || echo '?')"
echo "✔ clean install done — TokenTerrier $VER is running. Check your menu bar."
