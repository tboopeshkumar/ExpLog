#!/bin/bash
# Renders the app icon PNG from Tools/IconGen/main.swift.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build
xcrun swiftc -O -target arm64-apple-macosx15.0 -o .build/icongen Tools/IconGen/main.swift
./.build/icongen "${1:-Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png}"
