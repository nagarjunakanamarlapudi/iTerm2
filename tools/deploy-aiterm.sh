#!/bin/bash
# Build AiTerm and deploy to Desktop with icon + patches
# Usage: tools/deploy-aiterm.sh [--skip-build]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$(ls -dt ~/Library/Developer/Xcode/DerivedData/iTerm2-*/Build/Products/Development 2>/dev/null | head -1)"
if [ -z "$BUILD_DIR" ]; then
    echo "Error: No iTerm2 build found in DerivedData. Run tools/build.sh first."
    exit 1
fi
DEST=~/Desktop/AiTerm.app
ICON="$PROJECT_DIR/images/AiTerm.icns"
ICON_PNG="/tmp/aiterm_icon_final.png"

if [ "$1" != "--skip-build" ]; then
    echo "Building..."
    cd "$PROJECT_DIR"
    tools/build.sh || exit 1
fi

echo "Deploying to Desktop..."
rm -rf "$DEST"
cp -R "$BUILD_DIR/iTerm2.app" "$DEST"

# Replace ALL icon variants (Asset Catalog overrides CFBundleIconFile)
cp "$ICON" "$DEST/Contents/Resources/AiTerm.icns"
cp "$ICON" "$DEST/Contents/Resources/iTerm2 App Icon for Nightly.icns"
if [ -f "$ICON_PNG" ]; then
    python3 -c "
from PIL import Image
img = Image.open('$ICON_PNG')
img.resize((256, 256), Image.LANCZOS).save('$DEST/Contents/Resources/AppIcon.png')
" 2>/dev/null
fi

# Patch Info.plist
VERSION="${AITERM_VERSION:-1.0.0}"
/usr/libexec/PlistBuddy -c "Set CFBundleIconFile AiTerm.icns" "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleIconName AppIcon" "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleName AiTerm" "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier com.nkanamar.aiterm" "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" "$DEST/Contents/Info.plist"

# Disable Sparkle auto-update (don't delete keys — Sparkle crashes without them)
/usr/libexec/PlistBuddy -c "Set SUFeedURL https://localhost/disabled" "$DEST/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set SUFeedURLForFinal https://localhost/disabled" "$DEST/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set SUFeedURLForTesting https://localhost/disabled" "$DEST/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add SUEnableAutomaticChecks bool false" "$DEST/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete SUPublicEDKey" "$DEST/Contents/Info.plist" 2>/dev/null || true

# Copy iTerm2 preferences to AiTerm's suite (if not already set up)
if ! defaults read com.nkanamar.aiterm.settings "New Bookmarks" &>/dev/null; then
    defaults export com.googlecode.iterm2 - 2>/dev/null | defaults import com.nkanamar.aiterm.settings - 2>/dev/null && \
        echo "  Preferences copied from iTerm2 to AiTerm suite" || true
fi
# Enforce AiTerm defaults
defaults write com.nkanamar.aiterm.settings "TabViewType" -int 2
# Don't override TabStyleWithAutomaticOption — use whatever was copied from iTerm2
defaults write com.nkanamar.aiterm.settings "NSQuitAlwaysKeepsWindows" -bool true

# No wrapper script needed — main.m auto-detects com.nkanamar.aiterm bundle ID
# and sets -suite com.nkanamar.aiterm.settings for isolated storage

# Ad-hoc code sign so the app runs on any Mac without Gatekeeper issues
codesign --force --deep --sign - "$DEST" 2>/dev/null
xattr -cr "$DEST"

# Re-register with Launch Services to update icon cache
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST" 2>/dev/null
touch "$DEST"

# Create DMG with drag-to-Applications layout
DMG_STAGING=$(mktemp -d)
DMG_RW="/tmp/AiTerm_rw.dmg"
DMG_PATH=~/Desktop/AiTerm.dmg

cp -R "$DEST" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Add background image (hidden folder convention)
mkdir -p "$DMG_STAGING/.background"
cp "$PROJECT_DIR/images/dmg_background.png" "$DMG_STAGING/.background/background.png"
cp "$PROJECT_DIR/images/dmg_background_1x.png" "$DMG_STAGING/.background/background_1x.png"

rm -f "$DMG_RW" "$DMG_PATH"

# Create a read-write DMG first so we can style it
hdiutil create -volname "AiTerm" -srcfolder "$DMG_STAGING" -ov -format UDRW "$DMG_RW" 2>/dev/null
rm -rf "$DMG_STAGING"

# Mount, style the Finder window, then unmount
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW" 2>&1)
MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | grep '/Volumes/' | sed 's/.*\(\/Volumes\/.*\)/\1/' | tr -d '\t ')
echo "Mounted at: $MOUNT_DIR"

if [ -n "$MOUNT_DIR" ]; then
    # Brief pause for Finder to index the volume
    sleep 2

    osascript <<'APPLESCRIPT'
    tell application "Finder"
        tell disk "AiTerm"
            open
            delay 2
            set cw to container window
            set current view of cw to icon view
            set toolbar visible of cw to false
            set statusbar visible of cw to false
            set sidebar width of cw to 0
            set bounds of cw to {200, 120, 760, 400}

            set theViewOptions to icon view options of cw
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 96
            set text size of theViewOptions to 12
            set background picture of theViewOptions to file ".background:background.png"

            -- Position icons over the background
            set position of item "AiTerm.app" of cw to {140, 140}
            delay 0.5
            set position of item "Applications" of cw to {420, 140}
            delay 0.5

            update without registering applications
            close
        end tell
    end tell
APPLESCRIPT
    sync
    sleep 1
    hdiutil detach "$MOUNT_DIR" 2>/dev/null
fi

# Convert to compressed read-only DMG
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH" 2>/dev/null
rm -f "$DMG_RW"

echo "AiTerm.app deployed to Desktop"
echo "AiTerm.dmg created at ~/Desktop/AiTerm.dmg"
