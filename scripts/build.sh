#!/bin/bash
# Compila y ensambla build/TasksBar.app.
#   UNIVERSAL=1  → binario arm64+x86_64
#   SIGN_ID="Developer ID Application: Nombre (TEAMID)" → firma real (por defecto ad-hoc; el Keychain pregunta en cada build: usa un cert. estable)
#   Config local sin commitear: copia .env.example a .env (SIGN_ID, NOTARY_PROFILE)
#   NOTARY_PROFILE=perfil → notariza y grapa el ticket (necesita SIGN_ID)
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
# Client ID fuera del repo: se lee de client.plist (ignorado por git).
CID=$(/usr/libexec/PlistBuddy -c "Print :CLIENT_ID" client.plist) || { echo "Falta client.plist con CLIENT_ID" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Add :CLIENT_ID string $CID" "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/TasksBar.entitlements --sign "${SIGN_ID:--}" "$APP"
# Notarización (requiere SIGN_ID Developer ID): NOTARY_PROFILE=<perfil de `xcrun notarytool store-credentials`>
if [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" build/TasksBar.zip
  xcrun notarytool submit build/TasksBar.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi
echo "OK → $APP"
