#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-package}"
APP_NAME="HySimulatranslate"
BUNDLE_ID="com.hysimulatranslate.app"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PAYLOAD_DIR="$APP_RESOURCES/HySimulatranslatePayload"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
SHERPA_LIB_DIR="$ROOT_DIR/Libraries/sherpa-onnx/lib"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
SHERPA_MODEL_SOURCE="${SHERPA_MODEL_SOURCE:-$HOME/Library/Application Support/SherpaOnnxModel/sherpa-onnx-streaming-zipformer-en-2023-06-26}"
WHISPER_MODEL_SOURCE="${WHISPER_MODEL_SOURCE:-$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3}"

usage() {
  echo "usage: $0 [package|--verify|verify]" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_dir() {
  [[ -d "$1" ]] || die "$2 not found: $1"
}

require_file() {
  [[ -f "$1" ]] || die "$2 not found: $1"
}

require_glob() {
  compgen -G "$1" >/dev/null || die "$2 not found: $1"
}

validate_inputs() {
  require_file "$ICON_FILE" "App icon"
  require_dir "$SHERPA_LIB_DIR" "sherpa-onnx dylib directory"
  require_glob "$SHERPA_LIB_DIR/*.dylib" "sherpa-onnx dylibs"

  require_dir "$SHERPA_MODEL_SOURCE" "Sherpa model source"
  require_glob "$SHERPA_MODEL_SOURCE/encoder*.onnx" "Sherpa encoder"
  require_glob "$SHERPA_MODEL_SOURCE/decoder*.onnx" "Sherpa decoder"
  require_glob "$SHERPA_MODEL_SOURCE/joiner*.onnx" "Sherpa joiner"
  require_file "$SHERPA_MODEL_SOURCE/tokens.txt" "Sherpa tokens"

  require_dir "$WHISPER_MODEL_SOURCE" "WhisperKit model source"
  require_dir "$WHISPER_MODEL_SOURCE/MelSpectrogram.mlmodelc" "WhisperKit MelSpectrogram.mlmodelc"
  require_dir "$WHISPER_MODEL_SOURCE/AudioEncoder.mlmodelc" "WhisperKit AudioEncoder.mlmodelc"
  require_dir "$WHISPER_MODEL_SOURCE/TextDecoder.mlmodelc" "WhisperKit TextDecoder.mlmodelc"
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>HySimulatranslate needs microphone access to transcribe live audio.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

copy_payload() {
  mkdir -p "$PAYLOAD_DIR/Models/Sherpa" "$PAYLOAD_DIR/Models/WhisperKit" "$PAYLOAD_DIR/Scripts"
  ditto "$SHERPA_MODEL_SOURCE" "$PAYLOAD_DIR/Models/Sherpa/$(basename "$SHERPA_MODEL_SOURCE")"
  ditto "$WHISPER_MODEL_SOURCE" "$PAYLOAD_DIR/Models/WhisperKit/$(basename "$WHISPER_MODEL_SOURCE")"
  ditto "$ROOT_DIR/script" "$PAYLOAD_DIR/Scripts"
}

build_app() {
  validate_inputs
  mkdir -p "$DIST_DIR"

  cd "$ROOT_DIR"
  swift build -c release
  BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
  require_file "$BUILD_BINARY" "Release binary"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  cp "$ICON_FILE" "$APP_RESOURCES/AppIcon.icns"
  cp "$SHERPA_LIB_DIR"/*.dylib "$APP_FRAMEWORKS/"
  copy_payload
  write_info_plist
}

sign_app() {
  if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign not found; skipping ad-hoc signing" >&2
    return
  fi

  while IFS= read -r -d '' code_path; do
    codesign --force --sign - "$code_path" >/dev/null
  done < <(find "$APP_FRAMEWORKS" -name '*.dylib' -print0)

  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
}

create_dmg() {
  rm -rf "$DMG_STAGING" "$DMG_PATH"
  mkdir -p "$DMG_STAGING"
  ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGING/Applications"
  printf "Install HySimulatranslate by dragging HySimulatranslate.app to Applications.\\n" \
    >"$DMG_STAGING/README.txt"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
}

verify_artifact() {
  require_file "$APP_RESOURCES/AppIcon.icns" "Bundled app icon"
  require_dir "$PAYLOAD_DIR/Models/Sherpa/$(basename "$SHERPA_MODEL_SOURCE")" "Bundled Sherpa model"
  require_dir "$PAYLOAD_DIR/Models/WhisperKit/$(basename "$WHISPER_MODEL_SOURCE")" "Bundled WhisperKit model"
  require_dir "$PAYLOAD_DIR/Scripts" "Bundled scripts"
  require_dir "$APP_FRAMEWORKS" "Bundled frameworks"
  require_glob "$APP_FRAMEWORKS/*.dylib" "Bundled dylibs"
  codesign --verify --deep --strict "$APP_BUNDLE"

  local mount_point=""
  mount_point="$(hdiutil attach "$DMG_PATH" -readonly -nobrowse | awk 'END {print $3}')"
  trap '[[ -n "$mount_point" ]] && hdiutil detach "$mount_point" >/dev/null 2>&1 || true' RETURN
  require_dir "$mount_point/$APP_NAME.app" "DMG app"
  [[ -L "$mount_point/Applications" ]] || die "DMG Applications shortcut not found"
}

case "$MODE" in
  package)
    build_app
    sign_app
    create_dmg
    ;;
  --verify|verify)
    build_app
    sign_app
    create_dmg
    verify_artifact
    ;;
  *)
    usage
    exit 2
    ;;
esac

echo "Created $DMG_PATH"
