#!/bin/bash
# Builds and packages build/TasksBar-<version>.zip and .dmg (uses SIGN_ID/NOTARY_PROFILE from .env, like build.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
./scripts/build.sh
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/TasksBar.app
ditto -c -k --keepParent "$APP" "build/TasksBar-$V.zip"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "build/TasksBar-$V.dmg"
hdiutil create -quiet -volname "Menu Tasks Bar" -srcfolder "$STAGE" -ov -format UDZO "build/TasksBar-$V.dmg"
rm -rf "$STAGE"
[ "${SIGN_ID:--}" != "-" ] && codesign --force --sign "$SIGN_ID" "build/TasksBar-$V.dmg"
echo "OK → build/TasksBar-$V.zip, build/TasksBar-$V.dmg"
