#!/bin/bash
# Fills the simulator's store with the sample messages, for screenshots.
# Usage: ./Tools/seed-demo.sh <simulator-udid>
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIM="${1:?usage: seed-demo.sh <simulator-udid>}"
# The bundle ID of the simulator build, whatever prefix it was built with.
APP_ID="${EXPLOG_APP_ID:-$(plutil -extract CFBundleIdentifier raw .build/dd/Build/Products/Debug-iphonesimulator/ExpLog.app/Info.plist 2>/dev/null)}"
[ -n "$APP_ID" ] || { echo "Build for the simulator first, or set EXPLOG_APP_ID."; exit 1; }

# Prefer the App Group container; fall back to the app's own, which is where the
# store lives when App Groups aren't available (free Apple ID).
GROUP=$(xcrun simctl get_app_container "$SIM" "$APP_ID" groups 2>/dev/null | head -1 | awk '{print $2}' || true)
if [ -n "$GROUP" ] && [ -d "$GROUP" ]; then
    STORE="$GROUP/ExpLog.store"
else
    DATA=$(xcrun simctl get_app_container "$SIM" "$APP_ID" data)
    mkdir -p "$DATA/Library/Application Support"
    STORE="$DATA/Library/Application Support/ExpLog.store"
fi

mkdir -p .build
xcrun swiftc -target arm64-apple-macosx15.0 -o .build/seeddemo \
    Shared/ParsedTransaction.swift Shared/SMSParser.swift Shared/MerchantFormat.swift Shared/LearnedParsing.swift Shared/Formatting.swift \
    Shared/SeedData.swift Shared/TransactionDraft.swift Shared/TransactionLink.swift Shared/AccountMatching.swift Shared/Currency.swift Shared/CurrencySettings.swift Shared/ExchangeRates.swift Shared/SharedStore.swift \
    Shared/Models/Models.swift Tools/SeedDemo/main.swift
./.build/seeddemo "$STORE"
