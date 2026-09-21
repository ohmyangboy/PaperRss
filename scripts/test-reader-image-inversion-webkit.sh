#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

probe_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/paperrss-image-invert-webkit.XXXXXX")"
trap 'rm -rf -- "$probe_temp_dir"' EXIT

xcrun swiftc -parse-as-library \
    Tests/ReaderImageInversionWebKitProbe.swift \
    -framework AppKit \
    -framework WebKit \
    -o "$probe_temp_dir/ReaderImageInversionWebKitProbe"

"$probe_temp_dir/ReaderImageInversionWebKitProbe" \
    PaperRss/Sources/App/ArticleReaderView.swift
