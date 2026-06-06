#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "🔨 FanSpeed 빌드 중..."

swiftc \
  Sources/SMCKit.swift \
  Sources/FanManager.swift \
  Sources/VerticalRPMSlider.swift \
  Sources/MenuView.swift \
  Sources/AppDelegate.swift \
  Sources/main.swift \
  -framework AppKit \
  -framework IOKit \
  -framework Foundation \
  -o FanSpeed

echo "✅ 빌드 완료: ./FanSpeed"
