#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

probe_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/paperrss-highlight-webkit.XXXXXX")"
trap 'rm -rf -- "$probe_temp_dir"' EXIT

xcrun swiftc -parse-as-library \
    Tests/CodeHighlightWebKitProbe.swift \
    -framework AppKit \
    -framework WebKit \
    -o "$probe_temp_dir/CodeHighlightWebKitProbe"

"$probe_temp_dir/CodeHighlightWebKitProbe" \
    PaperRss/Resources/Highlight/highlight.min.js \
    PaperRss/Sources/App/ArticleReaderView.swift \
    Tests/fixtures/highlight-pygments-article.html
