#!/bin/bash
# Exercises models, draft logic and SwiftData persistence on macOS — no
# simulator needed. Requires Xcode (for the SwiftData macros).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build
xcrun swiftc -target arm64-apple-macosx15.0 -o .build/storecheck \
    Shared/ParsedTransaction.swift \
    Shared/SMSParser.swift \
    Shared/Formatting.swift \
    Shared/SeedData.swift \
    Shared/TransactionDraft.swift Shared/TransactionLink.swift \
    Shared/Models/Models.swift \
    Tools/StoreCheck/main.swift
exec ./.build/storecheck
