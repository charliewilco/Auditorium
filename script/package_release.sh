#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-"$ROOT/dist"}"
DERIVED_DATA="${DERIVED_DATA:-"$ROOT/.build/xcode-release"}"
ARCHIVE_PATH="${ARCHIVE_PATH:-"$OUTPUT_DIR/Auditorium.xcarchive"}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-"$ROOT/config/ExportOptions-developer-id.plist"}"
SYMPHONY_BINARY="$ROOT/target/auditorium-universal-release/symphony"
MODE="development"
NOTARIZE=0

build_symphony() {
	rustup target add aarch64-apple-darwin x86_64-apple-darwin
	cargo build --release -p symphony --target aarch64-apple-darwin
	cargo build --release -p symphony --target x86_64-apple-darwin
	mkdir -p "$(dirname "$SYMPHONY_BINARY")"
	lipo -create \
		"$ROOT/target/aarch64-apple-darwin/release/symphony" \
		"$ROOT/target/x86_64-apple-darwin/release/symphony" \
		-output "$SYMPHONY_BINARY"
	lipo "$SYMPHONY_BINARY" -verify_arch arm64 x86_64
}

copy_symphony_into_app() {
	local app="$1"
	local bin_dir="$app/Contents/Resources/bin"
	mkdir -p "$bin_dir"
	ditto "$SYMPHONY_BINARY" "$bin_dir/symphony"
	chmod 755 "$bin_dir/symphony"
}

verify_packaged_architectures() {
	local app="$1"
	local app_binary="$app/Contents/MacOS/Auditorium"
	local symphony_binary="$app/Contents/Resources/bin/symphony"
	local architecture

	for architecture in $(lipo -archs "$app_binary"); do
		lipo "$symphony_binary" -verify_arch "$architecture"
	done
}

usage() {
	cat <<'USAGE'
Usage: script/package_release.sh [--unsigned | --developer-id] [--notarize]

Modes:
  development   Build a Release app with local Apple Development signing. Default.
  --unsigned    Build an unsigned Release app zip for CI smoke artifacts.
  --developer-id
                Archive and export with Developer ID signing for distribution.

Environment for --notarize:
  NOTARYTOOL_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--unsigned)
			MODE="unsigned"
			shift
			;;
		--developer-id)
			MODE="developer-id"
			shift
			;;
		--notarize)
			NOTARIZE=1
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
	esac
done

if [[ "$NOTARIZE" -eq 1 && "$MODE" != "developer-id" ]]; then
	printf 'Notarization requires --developer-id.\n' >&2
	exit 2
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ "$MODE" == "developer-id" ]]; then
	build_symphony

	xcodebuild archive \
		-workspace "$ROOT/Auditorium.xcworkspace" \
		-scheme Auditorium \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-archivePath "$ARCHIVE_PATH"

	copy_symphony_into_app "$ARCHIVE_PATH/Products/Applications/Auditorium.app"

	xcodebuild -exportArchive \
		-archivePath "$ARCHIVE_PATH" \
		-exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
		-exportPath "$OUTPUT_DIR/export"

	APP="$OUTPUT_DIR/export/Auditorium.app"
else
	SIGNING_ALLOWED=YES
	if [[ "$MODE" == "unsigned" ]]; then
		SIGNING_ALLOWED=NO
	fi

	xcodebuild build \
		-workspace "$ROOT/Auditorium.xcworkspace" \
		-scheme Auditorium \
		-configuration Release \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$DERIVED_DATA" \
		CODE_SIGNING_ALLOWED="$SIGNING_ALLOWED"

	APP="$OUTPUT_DIR/Auditorium.app"
	ditto "$DERIVED_DATA/Build/Products/Release/Auditorium.app" "$APP"
	build_symphony
	copy_symphony_into_app "$APP"
	if [[ "$MODE" == "development" || "$MODE" == "unsigned" ]]; then
		codesign --force --deep --sign - "$APP"
	fi
fi

verify_packaged_architectures "$APP"

if [[ "$MODE" != "unsigned" ]]; then
	codesign --verify --deep --strict --verbose=2 "$APP"
fi

ZIP="$OUTPUT_DIR/Auditorium.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ "$NOTARIZE" -eq 1 ]]; then
	if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
		xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
	elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
		xcrun notarytool submit "$ZIP" \
			--apple-id "$APPLE_ID" \
			--team-id "$APPLE_TEAM_ID" \
			--password "$APPLE_APP_SPECIFIC_PASSWORD" \
			--wait
	else
		printf 'Set NOTARYTOOL_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD for notarization.\n' >&2
		exit 2
	fi

	xcrun stapler staple "$APP"
	spctl -a -vv "$APP"
	rm -f "$ZIP"
	ditto -c -k --keepParent "$APP" "$ZIP"
fi

printf 'Packaged %s\n' "$ZIP"
