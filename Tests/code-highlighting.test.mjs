import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, "..");
const highlightDir = path.join(projectRoot, "PaperRss", "Resources", "Highlight");
const scriptPath = path.join(highlightDir, "highlight.min.js");
const licensePath = path.join(highlightDir, "LICENSE");
const packageManifestPath = path.join(projectRoot, "Package.swift");
const readerSourcePath = path.join(projectRoot, "PaperRss", "Sources", "App", "ArticleReaderView.swift");

describe("highlight.js 11.11.2 Offline Runtime Integrity and Wiring", () => {
  it("highlight.js 11.11.2 files exist and match exact SHA-256 checksums", () => {
    assert.ok(fs.existsSync(scriptPath), "highlight.min.js must exist locally");
    assert.ok(fs.existsSync(licensePath), "LICENSE must exist locally");

    const scriptHash = crypto.createHash("sha256").update(fs.readFileSync(scriptPath)).digest("hex");
    assert.equal(
      scriptHash,
      "62960a35954a685dbe12958092f661a185231e9f5f5c44dc3c1e237d9e087d5a",
      "highlight.min.js SHA-256 hash must match documented release"
    );

    const licenseHash = crypto.createHash("sha256").update(fs.readFileSync(licensePath)).digest("hex");
    assert.equal(
      licenseHash,
      "6c081431591d9df696c82dc598fe1423765b8a299b200ed00b281afd0f64c490",
      "LICENSE SHA-256 hash must match BSD 3-Clause license file"
    );
  });

  it("highlight.js bundle is a self-contained offline component without CDN endpoints", () => {
    const scriptText = fs.readFileSync(scriptPath, "utf8");
    assert.match(scriptText, /Highlight\.js v11\.11\.2/, "Bundle header must pin the documented version");
    assert.match(scriptText, /License: BSD-3-Clause/, "Bundle header must retain BSD-3-Clause attribution");
    assert.ok(!scriptText.includes("cdnjs.cloudflare.com"), "Must not contain cdnjs endpoint");
    assert.ok(!scriptText.includes("jsdelivr"), "Must not contain jsdelivr endpoint");
    assert.ok(!scriptText.includes("unpkg.com"), "Must not contain unpkg endpoint");
  });

  it("SwiftPM bundles the Highlight resource directory", () => {
    const manifest = fs.readFileSync(packageManifestPath, "utf8");
    assert.match(manifest, /\.copy\("\.\.\/\.\.\/Resources\/Highlight"\)/);
  });

  it("Reader bridge gates runtime evaluation on language-tagged code blocks", () => {
    const source = fs.readFileSync(readerSourcePath, "utf8");
    const bridgeStart = source.indexOf("enum PaperReaderBridge");
    const bridgeEnd = source.indexOf("#if os(macOS)\nprivate final class ArticleWebViewContainer", bridgeStart);
    const bridge = source.slice(bridgeStart, bridgeEnd);

    assert.match(bridge, /loadHighlightRuntimeSource\(\)/, "Loader must exist");
    assert.match(bridge, /"Highlight"/, "Loader must resolve the Highlight resource subdirectory");
    assert.match(bridge, /Resources\/Highlight/, "Loader must keep the SPM fallback path");

    const injectStart = bridge.indexOf("static func injectCodeHighlightRuntime");
    const injectEnd = bridge.indexOf("static func isSameDocumentAnchor", injectStart);
    const inject = bridge.slice(injectStart, injectEnd);
    const gateMatch = inject.match(/querySelectorAll\(([^)]+)\)/);
    assert.ok(gateMatch, "Gate must use querySelectorAll");
    assert.ok(
      gateMatch[1].includes("language-") && gateMatch[1].includes("lang-"),
      "Gate must cover both language- and lang- prefixes (lang- alone cannot match language-python)"
    );
    assert.match(inject, /Boolean\(window\.hljs\)/, "Runtime evaluation must be idempotent per document");
    assert.match(inject, /contentWorld: \.page/, "Highlighting must run in the page world like MathJax");
  });

  it("Highlight pass only colors declared languages and stays idempotent", () => {
    const source = fs.readFileSync(readerSourcePath, "utf8");
    const bodyStart = source.indexOf("codeHighlightScriptBody");
    const bodyEnd = source.indexOf("static func injectCodeHighlightRuntime", bodyStart);
    const glue = source.slice(bodyStart, bodyEnd);

    assert.match(glue, /\^\(\?:language\|lang\)-/, "Glue must require an explicit language marker");
    assert.match(glue, /getLanguage\(language\)/, "Glue must skip languages missing from the bundle (no auto-guess)");
    assert.match(glue, /dataset\.paperHljs/, "Glue must mark processed blocks to stay idempotent");
    assert.match(glue, /querySelectorAll\('pre code'\)/, "Glue must only touch block code, not inline code");
    assert.match(glue, /paperRssLayoutRefresh/, "Glue must refresh reader layout after highlighting");
  });

  it("Both platform coordinators inject highlighting after navigation finishes", () => {
    const source = fs.readFileSync(readerSourcePath, "utf8");
    const macOSStart = source.indexOf("private struct ArticleHTMLView: NSViewRepresentable");
    const macOSCoordinator = source.slice(macOSStart, source.indexOf("#if os(iOS)", macOSStart));
    const iOSCoordinator = source.slice(source.indexOf("private struct ArticleHTMLView: UIViewRepresentable"));

    for (const coordinator of [macOSCoordinator, iOSCoordinator]) {
      assert.match(coordinator, /injectCodeHighlightingIfNeeded\(in webView: WKWebView\)/);
      assert.match(coordinator, /lastCodeHighlightInjectionKey/);
      assert.match(
        coordinator,
        /injectMathJaxRuntimeIfNeeded\(in: webView\)\s*\n\s*self\.injectCodeHighlightingIfNeeded\(in: webView\)/,
        "didFinish must schedule highlighting right after the MathJax injection hook"
      );
    }
  });

  it("Paper theme defines highlight token colors for light and dark palettes", () => {
    const source = fs.readFileSync(readerSourcePath, "utf8");
    const styleStart = source.indexOf("private let paperArticleStyle");
    const styleEnd = source.indexOf("private func readerAppearanceStyle", styleStart);
    const style = source.slice(styleStart, styleEnd);

    const lightBlock = style.slice(0, style.indexOf("@media (prefers-color-scheme: dark)"));
    const darkBlock = style.slice(style.indexOf("@media (prefers-color-scheme: dark)"));

    for (const token of ["comment", "keyword", "string", "number", "title"]) {
      assert.match(lightBlock, new RegExp(`--paper-code-${token}:`), `Light palette must define --paper-code-${token}`);
      assert.match(darkBlock, new RegExp(`--paper-code-${token}:`), `Dark palette must define --paper-code-${token}`);
      assert.match(style, new RegExp(`pre code \\.hljs-[^\\n]*${token}\\b`), `Token rules must style .hljs-${token}`);
    }
  });
});
