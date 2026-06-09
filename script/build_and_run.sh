#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-"$ROOT/.build/xcode-run"}"
CONFIGURATION="${CONFIGURATION:-Debug}"
MODE="run"
VERIFY=0

usage() {
	printf 'Usage: %s [--verify|--debug|--logs|--telemetry] [--configuration Debug|Release]\n' "$0"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--verify)
			MODE="verify"
			VERIFY=1
			shift
			;;
		--debug)
			MODE="debug"
			shift
			;;
		--logs)
			MODE="logs"
			shift
			;;
		--telemetry)
			MODE="telemetry"
			shift
			;;
		--configuration)
			CONFIGURATION="${2:?missing configuration}"
			shift 2
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

if pgrep -x Auditorium >/dev/null; then
	pkill -x Auditorium
	sleep 1
fi

xcodebuild build \
	-workspace "$ROOT/Auditorium.xcworkspace" \
	-scheme Auditorium \
	-configuration "$CONFIGURATION" \
	-destination 'platform=macOS,arch=arm64' \
	-derivedDataPath "$DERIVED_DATA" \
	CODE_SIGNING_ALLOWED=NO

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Auditorium.app"
APP_BINARY="$APP/Contents/MacOS/Auditorium"

case "$MODE" in
	debug)
		exec lldb -- "$APP_BINARY"
		;;
	run|verify|logs|telemetry)
		/usr/bin/open -n "$APP"
		;;
esac

if [[ "$MODE" == "logs" ]]; then
	exec /usr/bin/log stream --info --style compact --predicate 'process == "Auditorium"'
fi

if [[ "$MODE" == "telemetry" ]]; then
	exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "co.charliewil.Auditorium"'
fi

if [[ "$VERIFY" -eq 1 ]]; then
	for _ in {1..30}; do
		if pgrep -x Auditorium >/dev/null; then
			printf 'Auditorium launched from %s\n' "$APP"
			exit 0
		fi
		sleep 1
	done
	printf 'Auditorium did not appear as a running process after launch.\n' >&2
	exit 1
fi
