#!/bin/bash
# Builds and assembles build/TasksBar.app.
#   UNIVERSAL=1  → arm64+x86_64 binary
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" → real signature (ad-hoc by default; the Keychain prompts on every build, so use a stable certificate)
#   Local uncommitted config: copy .env.example to .env (SIGN_ID, NOTARY_PROFILE)
#   NOTARY_PROFILE=profile → notarizes and staples the ticket (needs SIGN_ID)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
ARCHS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/TasksBar"
APP=build/TasksBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"; cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
# Client ID kept out of the repo: read from client.plist (ignored by git).
CID=$(/usr/libexec/PlistBuddy -c "Print :CLIENT_ID" client.plist) || { echo "Missing client.plist with CLIENT_ID" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Add :CLIENT_ID string $CID" "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/TasksBar.entitlements --sign "${SIGN_ID:--}" "$APP"
# Notarization (requires a Developer ID SIGN_ID): NOTARY_PROFILE=<profile from `xcrun notarytool store-credentials`>
if [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" build/TasksBar.zip
  xcrun notarytool submit build/TasksBar.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi
echo "OK → $APP"
