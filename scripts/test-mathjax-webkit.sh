#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

probe_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/paperrss-mathjax-webkit.XXXXXX")"
trap 'rm -rf -- "$probe_temp_dir"' EXIT

xcrun swiftc -parse-as-library \
    Tests/MathJaxWebKitProbe.swift \
    -framework AppKit \
    -framework WebKit \
    -o "$probe_temp_dir/MathJaxWebKitProbe"

"$probe_temp_dir/MathJaxWebKitProbe" \
    PaperRss/Resources/MathJax/paper-rss-config.js \
    PaperRss/Resources/MathJax/tex-mml-svg.js
