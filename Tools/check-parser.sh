#!/bin/bash
# Runs the SMS parser regression suite on macOS — no Xcode or simulator needed.
set -e
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -o .build/parsercheck \
    Shared/ParsedTransaction.swift \
    Shared/SMSParser.swift \
    Tools/ParserCheck/main.swift
exec ./.build/parsercheck
