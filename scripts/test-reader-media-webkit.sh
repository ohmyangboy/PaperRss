#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/paperrss-reader-media.XXXXXX")"
trap 'rm -rf -- "$probe_temp_dir"' EXIT
xcrun swiftc -parse-as-library Tests/ReaderMediaLoadingWebKitProbe.swift \
    -framework AppKit -framework WebKit -o "$probe_temp_dir/ReaderMediaLoadingWebKitProbe"
"$probe_temp_dir/ReaderMediaLoadingWebKitProbe"
"$probe_temp_dir/ReaderMediaLoadingWebKitProbe" video
