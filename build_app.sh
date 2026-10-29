#!/bin/bash
# Construit Catchup.app dans ./build et (optionnellement) l'installe dans /Applications.
#   ./build_app.sh              → build/Catchup.app (architecture du Mac courant)
#   ./build_app.sh --install    → copie aussi dans /Applications
#   ./build_app.sh --release    → app universelle (Apple Silicon + Intel) + build/Catchup.zip à publier
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Catchup"
APP="build/${APP_NAME}.app"
INSTALL=0
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    *) echo "Option inconnue : $arg" >&2; exit 1 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ $RELEASE == 1 ]]; then
  # Une compilation par architecture puis fusion avec lipo : fonctionne aussi avec
  # les seuls Command Line Tools (--arch arm64 --arch x86_64 exige Xcode complet).
  # Un dossier de compilation par architecture : partagé, SwiftPM échoue au 2e passage.
  BINS=()
  for arch in arm64 x86_64; do
    echo "▸ Compilation (release, $arch)…"
    opts=(-c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/universal-$arch")
    swift build "${opts[@]}"
    BINS+=("$(swift build "${opts[@]}" --show-bin-path)/CatchupDownloader")
  done
  echo "▸ Fusion en binaire universel…"
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  echo "▸ Compilation (release)…"
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/CatchupDownloader" "$APP/Contents/MacOS/$APP_NAME"
fi

echo "▸ Assemblage du bundle…"
cp Sources/CatchupDownloader/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"  # traductions

echo "▸ Icône…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Signature ad hoc…"
codesign --force --deep --sign - "$APP" >/dev/null

if [[ $RELEASE == 1 ]]; then
  echo "▸ Archive…"
  rm -f "build/${APP_NAME}.zip"
  # ditto conserve la signature et les attributs étendus (contrairement à zip).
  ditto -c -k --sequesterRsrc --keepParent "$APP" "build/${APP_NAME}.zip"
  echo "✓ build/${APP_NAME}.zip ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
fi

if [[ $INSTALL == 1 ]]; then
  echo "▸ Installation dans /Applications…"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  echo "✓ /Applications/${APP_NAME}.app"
else
  echo "✓ $APP"
fi
