#!/bin/bash
set -e
cd "$(dirname "$0")"

# Command Line Tools만으로 빌드할 수 있다. 시스템의 Xcode 선택 설정은 바꾸지 않는다.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

echo "🔨 FanSpeed 빌드 중... (Apple Silicon + Intel, macOS 11 이상)"
fan_speed_build_dir=$(mktemp -d /tmp/fanspeed-build.XXXXXX)
trap 'rm -rf "$fan_speed_build_dir"' EXIT
for fan_speed_arch in arm64 x86_64; do
  swiftc \
    Sources/SMCKit.swift \
    Sources/FanManager.swift \
    Sources/VerticalRPMSlider.swift \
    Sources/MenuView.swift \
    Sources/AppDelegate.swift \
    Sources/main.swift \
    -target "$fan_speed_arch-apple-macos11.0" \
    -framework AppKit \
    -framework IOKit \
    -framework Foundation \
    -o "$fan_speed_build_dir/FanSpeed-$fan_speed_arch"
done
lipo -create "$fan_speed_build_dir/FanSpeed-arm64" "$fan_speed_build_dir/FanSpeed-x86_64" \
  -output FanSpeed
# fat 바이너리를 합친 후 로컬 실행용 ad-hoc 서명을 생성한다.
codesign --force --sign - FanSpeed

echo "✅ 빌드 완료: ./FanSpeed"
