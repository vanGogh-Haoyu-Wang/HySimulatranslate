#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHERPA_LIB_DIR="$ROOT_DIR/Libraries/sherpa-onnx/lib"
APP_SUPPORT_MODEL_ROOT="$HOME/Library/Application Support/HySimulatranslate/Models"
SHERPA_MODEL_SOURCE="${SHERPA_MODEL_SOURCE:-$APP_SUPPORT_MODEL_ROOT/Sherpa/sherpa-onnx-streaming-zipformer-en-2023-06-26}"
WHISPER_DOWNLOAD_BASE="${WHISPER_DOWNLOAD_BASE:-$APP_SUPPORT_MODEL_ROOT/WhisperKit}"
WHISPER_MODEL_SOURCE="${WHISPER_MODEL_SOURCE:-$WHISPER_DOWNLOAD_BASE/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB}"
VAD_MODEL_SOURCE="${VAD_MODEL_SOURCE:-$APP_SUPPORT_MODEL_ROOT/VAD/silero_vad.onnx}"

SHERPA_NPM_VERSION="${SHERPA_NPM_VERSION:-1.13.2}"
SHERPA_NPM_PACKAGE="${SHERPA_NPM_PACKAGE:-sherpa-onnx-darwin-arm64}"
SHERPA_NPM_BASE_URL="${SHERPA_NPM_BASE_URL:-https://unpkg.com/$SHERPA_NPM_PACKAGE@$SHERPA_NPM_VERSION}"
SHERPA_MODEL_URL="${SHERPA_MODEL_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2}"
VAD_MODEL_URL="${VAD_MODEL_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx}"

MODE="${1:---runtime}"

usage() {
  echo "usage: $0 [--runtime|--all]" >&2
}

download_file() {
  local url="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"
  local temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  curl --fail --location --retry 3 --connect-timeout 20 --output "$temporary" "$url"
  mv "$temporary" "$destination"
}

ensure_sherpa_libraries() {
  mkdir -p "$SHERPA_LIB_DIR"

  if [[ -f "$SHERPA_LIB_DIR/libsherpa-onnx-c-api.dylib" && -f "$SHERPA_LIB_DIR/libonnxruntime.dylib" ]]; then
    return
  fi

  echo "Downloading sherpa-onnx macOS dynamic libraries..."
  download_file "$SHERPA_NPM_BASE_URL/libsherpa-onnx-c-api.dylib" "$SHERPA_LIB_DIR/libsherpa-onnx-c-api.dylib"
  download_file "$SHERPA_NPM_BASE_URL/libonnxruntime.dylib" "$SHERPA_LIB_DIR/libonnxruntime.dylib"

  local versioned_name
  versioned_name="$(curl --fail --location --silent "$SHERPA_NPM_BASE_URL/" \
    | sed -n 's/.*href="[^"]*\\(libonnxruntime\\.[0-9][^"/]*\\.dylib\\)".*/\\1/p' \
    | head -n 1 || true)"
  if [[ -n "$versioned_name" ]]; then
    download_file "$SHERPA_NPM_BASE_URL/$versioned_name" "$SHERPA_LIB_DIR/$versioned_name"
  fi
}

ensure_sherpa_model() {
  if [[ -d "$SHERPA_MODEL_SOURCE" \
    && -n "$(find "$SHERPA_MODEL_SOURCE" -maxdepth 1 -name 'encoder*.onnx' -print -quit 2>/dev/null)" \
    && -n "$(find "$SHERPA_MODEL_SOURCE" -maxdepth 1 -name 'decoder*.onnx' -print -quit 2>/dev/null)" \
    && -n "$(find "$SHERPA_MODEL_SOURCE" -maxdepth 1 -name 'joiner*.onnx' -print -quit 2>/dev/null)" \
    && -f "$SHERPA_MODEL_SOURCE/tokens.txt" ]]; then
    return
  fi

  echo "Downloading Sherpa streaming ASR model..."
  local parent archive staging extracted
  parent="$(dirname "$SHERPA_MODEL_SOURCE")"
  archive="$parent/$(basename "$SHERPA_MODEL_SOURCE").tar.bz2"
  staging="$parent/.download-$(basename "$SHERPA_MODEL_SOURCE")"
  rm -rf "$staging"
  mkdir -p "$parent" "$staging"
  download_file "$SHERPA_MODEL_URL" "$archive"
  tar -xjf "$archive" -C "$staging"
  extracted="$staging/$(basename "$SHERPA_MODEL_SOURCE")"
  [[ -d "$extracted" ]] || {
    echo "error: extracted Sherpa model folder not found: $extracted" >&2
    exit 1
  }
  rm -rf "$SHERPA_MODEL_SOURCE"
  mv "$extracted" "$SHERPA_MODEL_SOURCE"
  rm -rf "$staging"
}

ensure_whisper_model() {
  if [[ -d "$WHISPER_MODEL_SOURCE/MelSpectrogram.mlmodelc" \
    && -d "$WHISPER_MODEL_SOURCE/AudioEncoder.mlmodelc" \
    && -d "$WHISPER_MODEL_SOURCE/TextDecoder.mlmodelc" ]]; then
    return
  fi

  echo "Downloading WhisperKit large-v3 model..."
  (cd "$ROOT_DIR" && swift run DependencyDownloader --whisper-download-base "$WHISPER_DOWNLOAD_BASE")
}

ensure_vad_model() {
  if [[ -f "$VAD_MODEL_SOURCE" ]]; then
    return
  fi

  echo "Downloading Silero VAD model..."
  download_file "$VAD_MODEL_URL" "$VAD_MODEL_SOURCE"
}

case "$MODE" in
  --runtime)
    ensure_sherpa_libraries
    ;;
  --all)
    ensure_sherpa_libraries
    ensure_sherpa_model
    ensure_vad_model
    ensure_whisper_model
    ;;
  *)
    usage
    exit 2
    ;;
esac
