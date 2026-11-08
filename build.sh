#!/bin/bash
# Compile ShareBar.app (universel Apple Silicon + Intel).
# Prérequis : outils en ligne de commande Xcode  →  xcode-select --install
# Les tests se lancent à part : swift test
# Usage : ./build.sh            (crée build/ShareBar.app)
#         ./build.sh --install  (et le copie dans /Applications)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ShareBar.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization -target "$arch-apple-macos13" \
    -framework AppKit -framework NetFS -framework ServiceManagement -framework Network \
    Sources/ShareBar/*.swift -o "build/ShareBar-$arch"
done
lipo -create build/ShareBar-arm64 build/ShareBar-x86_64 -output "$APP/Contents/MacOS/ShareBar"
rm build/ShareBar-arm64 build/ShareBar-x86_64
cp Resources/Info.plist "$APP/Contents/"
xattr -cr "$APP"  # codesign refuse les attributs étendus (Finder, quarantaine)
codesign --force --sign - "$APP"

echo "OK : $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x ShareBar 2>/dev/null && while pgrep -x ShareBar >/dev/null; do sleep 0.2; done  # sinon open échoue (-600)
  rm -rf /Applications/ShareBar.app
  cp -R "$APP" /Applications/
  open /Applications/ShareBar.app 2>/dev/null || { sleep 1; open /Applications/ShareBar.app; }  # -600 si LaunchServices n'a pas fini
  echo "Installé dans /Applications"
fi
