#!/bin/zsh
# Packages build/Breeze.app (from scripts/build-app.sh) into dist/Breeze-<version>.dmg and .zip.
#
# Plain run: ad hoc or Developer ID signed, not notarized. Friends must allow the app once in
# System Settings → Privacy & Security ("Open Anyway").
#
# Notarized run (needs the Apple Developer Program, a "Developer ID Application" certificate in the
# keychain so build-app.sh signs with it, and a notarytool keychain profile created once with
#   xcrun notarytool store-credentials breeze --apple-id you@example.com --team-id TEAMID --password <app-specific password>
# ):
#   NOTARY_PROFILE=breeze scripts/make-dist.sh
# The DMG then opens on any Mac with no warning.
set -euo pipefail
cd "$(dirname "$0")/.."
export TZ=UTC            # archive timestamps carry no local time zone
export COPYFILE_DISABLE=1 # no ._ AppleDouble sidecars in the zip; they break codesign --verify after a plain unzip
APP=build/Breeze.app
[[ -d "$APP" ]] || { echo "run scripts/build-app.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
PROFILE=${NOTARY_PROFILE:-}
rm -rf dist; mkdir -p dist

# Keep the matching dSYM (never published: it names the build machine's source paths) so crash
# reports from this version can be symbolicated later. symbols/ is gitignored.
if [[ -d build/Breeze.dSYM ]]; then
  mkdir -p symbols; rm -rf "symbols/Breeze-$VERSION.dSYM"; cp -R build/Breeze.dSYM "symbols/Breeze-$VERSION.dSYM"
  echo "▸ symbols/Breeze-$VERSION.dSYM ($(dwarfdump --uuid "symbols/Breeze-$VERSION.dSYM" | awk '{print $2}' | head -1))"
else
  echo "! build/Breeze.dSYM missing; crash reports for this version will not symbolicate"
fi

if [[ -n "$PROFILE" ]]; then
  codesign -dv "$APP" 2>&1 | grep -q "Developer ID" || { echo "notarization needs a Developer ID signature (see scripts/build-app.sh)"; exit 1; }
  echo "▸ notarizing the app"
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/notarize.zip
fi

echo "▸ dist/Breeze-$VERSION.zip"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "dist/Breeze-$VERSION.zip"

echo "▸ dist/Breeze-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Breeze" -srcfolder "$STAGE" -ov -format UDZO -quiet "dist/Breeze-$VERSION.dmg"
cp "dist/Breeze-$VERSION.dmg" dist/Breeze.dmg   # the site links releases/latest/download/Breeze.dmg
rm -rf "$STAGE"
if [[ -n "$PROFILE" ]]; then
  echo "▸ notarizing the disk image"
  xcrun notarytool submit "dist/Breeze-$VERSION.dmg" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "dist/Breeze-$VERSION.dmg"
fi

shasum -a 256 dist/*
