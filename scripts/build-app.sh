#!/bin/zsh
# Builds Breeze.app into ./build and optionally installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
APP=build/Breeze.app

# App Intents (Siri / Shortcuts) metadata: Xcode does this automatically; for a SwiftPM build we ask the
# compiler to emit const values for the AppIntents protocols and run Apple's processor over them.
AI_DIR="$PWD/build/appintents"
mkdir -p "$AI_DIR"
EXTRA_FLAGS=()
if [[ "$CONFIG" == "release" ]]; then
  cat > "$AI_DIR/protocols.json" <<'JSON'
["AppIntent","AppEntity","AppEnum","AppShortcutsProvider","AppShortcutsContent","EntityQuery","EntityStringQuery","EntityPropertyQuery","EnumerableEntityQuery","DynamicOptionsProvider","TransientAppEntity","IndexedEntity","UniqueAppEntity","AppIntentsPackage","AppDependencyManager","AssistantIntent","AssistantEntity","AssistantEnum","AssistantSchemaIntent","URLRepresentableIntent","URLRepresentableEntity","URLRepresentableEnum","OpenIntent","SystemIntent","SetValueIntent","DeleteIntent","ProgressReportingIntent","PredictableIntent","ForegroundContinuableIntent","ShowInAppSearchResultsIntent","ControlConfigurationIntent","WidgetConfigurationIntent","SnippetIntent","TargetContentProvidingIntent","ResolverRule","LiveActivityIntent","AudioPlaybackIntent","AudioRecordingIntent"]
JSON
  rm -f "$AI_DIR/Breeze.swiftconstvalues"
  touch Sources/Breeze/Intents.swift   # make sure the Breeze module (not just MideaKit) rewrites the const values
  EXTRA_FLAGS=(-Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$AI_DIR/protocols.json"
               -Xswiftc -emit-const-values-path -Xswiftc "$AI_DIR/Breeze.swiftconstvalues")
fi

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --product Breeze "${EXTRA_FLAGS[@]}" 2>&1 | grep -E "error|warning: var|Build complete|Build of" | grep -v "^\[" || true
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Breeze
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Keep a dSYM beside the build for symbolicating crash reports, then strip the executable: a SwiftPM
# release binary carries STABS entries naming every source file and object file by absolute path.
dsymutil "$BIN" -o build/Breeze.dSYM >/dev/null 2>&1 || echo "! dsymutil failed; this build has no dSYM"
cp "$BIN" "$APP/Contents/MacOS/Breeze"
strip -S -x "$APP/Contents/MacOS/Breeze"
cp scripts/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
cp Resources/stone-light.jpg Resources/stone-dark.jpg "$APP/Contents/Resources/"   # the house-style stone ground

if [[ "$CONFIG" == "release" && -f "$AI_DIR/Breeze.swiftconstvalues" ]] && grep -q '"Breeze\.' "$AI_DIR/Breeze.swiftconstvalues"; then
  echo "▸ App Intents metadata"
  ls "$PWD"/Sources/Breeze/*.swift > "$AI_DIR/sources.txt"
  echo "$AI_DIR/Breeze.swiftconstvalues" > "$AI_DIR/constvals.txt"
  rm -rf "$AI_DIR/out"; mkdir -p "$AI_DIR/out"
  PROC=$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
  XCV=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')
  if [[ -n "$PROC" ]]; then
    "$PROC" --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" --module-name Breeze \
      --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "${XCV:-17C529}" --platform-family macOS \
      --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
      --source-file-list "$AI_DIR/sources.txt" --swift-const-vals-list "$AI_DIR/constvals.txt" \
      --output "$AI_DIR/out" --force 2>&1 | grep -iE "error|warning" || true
    if [[ -d "$AI_DIR/out/Metadata.appintents" ]]; then
      cp -R "$AI_DIR/out/Metadata.appintents" "$APP/Contents/Resources/"
      echo "  ✓ Metadata.appintents embedded ($(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['actions']))" "$AI_DIR/out/Metadata.appintents/extract.actionsdata") actions)"
    else
      echo "  ! metadata processor produced nothing; Shortcuts actions will be unavailable"
    fi
  fi
fi

if [[ -f build/AppIcon.icns ]]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif command -v swift >/dev/null && [[ -f scripts/make-icon.swift ]]; then
  echo "▸ rendering app icon"
  mkdir -p build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY=${CODESIGN_IDENTITY:-}
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
fi
if [[ -z "$IDENTITY" ]]; then
  # A free Apple ID signed into Xcode yields an "Apple Development" certificate: stable across rebuilds on this Mac.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
fi
if [[ -n "$IDENTITY" ]]; then
  echo "▸ codesign ($IDENTITY, hardened runtime)"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" --identifier com.arikalabs.breeze "$APP"
else
  echo "▸ codesign (ad hoc — set CODESIGN_IDENTITY or add a Developer ID certificate for a stable signature)"
  codesign --force --deep --sign - --identifier com.arikalabs.breeze "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi

echo "✓ built $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Breeze.app
  cp -R "$APP" ~/Applications/Breeze.app
  echo "✓ installed to ~/Applications/Breeze.app"
fi
if [[ "${1:-}" == "--run" || "${2:-}" == "--run" ]]; then
  pkill -x Breeze 2>/dev/null || true
  open "${HOME}/Applications/Breeze.app" 2>/dev/null || open "$APP"
fi
