#!/bin/sh
# Builds GitView (Debug) and installs it to ~/Applications with its Finder extension.
# Usage: scripts/install-local.sh [--no-build]
set -eu

cd "$(dirname "$0")/.."
DERIVED=".build/XcodeDerivedData"
BUILT="$DERIVED/Build/Products/Debug/GitView.app"
APP="$HOME/Applications/GitView.app"
EXT_ID="com.local.GitView.FinderExtension"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "${1:-}" != "--no-build" ]; then
    xcodebuild -project GitView.xcodeproj -scheme GitView -configuration Debug \
        -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
fi

osascript -e 'quit app "GitView"' 2>/dev/null || true

# 1. Forget the copy in the build folder first. It has the same extension ID,
#    so unregistering it after installing would also drop the installed extension.
pluginkit -r "$BUILT/Contents/PlugIns/GitViewFinderExtension.appex" 2>/dev/null || true
"$LSREGISTER" -u "$PWD/$BUILT" 2>/dev/null || true

# 2. Install. ditto keeps the build folder's old date and macOS caches icons by
#    path and date, so touch the app or the Dock/Spotlight can keep a blank icon.
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$BUILT" "$APP"
touch "$APP"

# 3. Register the installed app and its extension last.
"$LSREGISTER" -f "$APP"
pluginkit -a "$APP/Contents/PlugIns/GitViewFinderExtension.appex"
pluginkit -e use -i "$EXT_ID"

# 4. Verify Finder can see the extension (registration can take a moment).
for attempt in 1 2 3 4 5; do
    if pluginkit -m -p com.apple.FinderSync | grep -q "$EXT_ID"; then
        echo "Installed $APP; Finder extension registered and enabled."
        exit 0
    fi
    sleep 1
    pluginkit -a "$APP/Contents/PlugIns/GitViewFinderExtension.appex"
    pluginkit -e use -i "$EXT_ID"
done
echo "Installed $APP, but the Finder extension is not registered. Open GitView once, then run this script again." >&2
exit 1
