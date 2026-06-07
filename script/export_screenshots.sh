#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${1:-"$ROOT/docs/acceptance/screenshots"}"
DERIVED_DATA="${DERIVED_DATA:-"$ROOT/.build/xcode-screenshots"}"

rm -rf "$SCREENSHOT_DIR"
mkdir -p "$SCREENSHOT_DIR"

xcodebuild build \
	-workspace "$ROOT/Auditorium.xcworkspace" \
	-scheme Auditorium \
	-configuration Debug \
	-destination 'platform=macOS,arch=arm64' \
	-derivedDataPath "$DERIVED_DATA" \
	CODE_SIGNING_ALLOWED=NO

APP="$DERIVED_DATA/Build/Products/Debug/Auditorium.app"
AUDITORIUM_EXPORT_SCREENSHOTS=1 AUDITORIUM_SCREENSHOT_DIR="$SCREENSHOT_DIR" "$APP/Contents/MacOS/Auditorium"
