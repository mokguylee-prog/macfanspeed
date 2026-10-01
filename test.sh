#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
fan_speed_test_dir=$(mktemp -d /tmp/fanspeed-tests.XXXXXX)
trap 'rm -rf "$fan_speed_test_dir"' EXIT
swiftc Sources/SMCKit.swift Sources/FanManager.swift Sources/VerticalRPMSlider.swift \
  Sources/MenuView.swift tests/main.swift -framework AppKit -framework IOKit \
  -framework Foundation -o "$fan_speed_test_dir/checks"
"$fan_speed_test_dir/checks" "$@"
