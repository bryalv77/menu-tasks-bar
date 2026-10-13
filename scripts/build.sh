#!/bin/bash
# Compila y ensambla build/TasksBar.app.
#   UNIVERSAL=1  → binario arm64+x86_64
#   SIGN_ID="Developer ID Application: Nombre (TEAMID)" → firma real (por defecto ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/TasksBar"
APP=build/TasksBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
echo "OK → $APP"
