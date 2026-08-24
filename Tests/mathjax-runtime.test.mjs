import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, "..");
const mathjaxDir = path.join(projectRoot, "PaperRss", "Resources", "MathJax");
const scriptPath = path.join(mathjaxDir, "tex-mml-svg.js");
const licensePath = path.join(mathjaxDir, "LICENSE");
const readerSourcePath = path.join(projectRoot, "PaperRss", "Sources", "App", "ArticleReaderView.swift");
const configPath = path.join(mathjaxDir, "paper-rss-config.js");

describe("MathJax 4.1.2 Offline Runtime Integrity and Safety", () => {
  it("MathJax 4.1.2 files exist and match exact SHA-256 checksums", () => {
    assert.ok(fs.existsSync(scriptPath), "tex-mml-svg.js must exist locally");
    assert.ok(fs.existsSync(licensePath), "LICENSE must exist locally");

    const scriptBuffer = fs.readFileSync(scriptPath);
    const scriptHash = crypto.createHash("sha256").update(scriptBuffer).digest("hex");
    assert.equal(
      scriptHash,
      "4fca13718f906c404bb98c6fba642ab7c1ffe545d91aa102b3aa6a231884dda3",
      "tex-mml-svg.js SHA-256 hash must match documented release"
    );

    const licenseBuffer = fs.readFileSync(licensePath);
    const licenseHash = crypto.createHash("sha256").update(licenseBuffer).digest("hex");
    assert.equal(
      licenseHash,
      "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
      "LICENSE SHA-256 hash must match Apache 2.0 license file"
    );
  });

  it("Offline WKWebView configuration disables unpackaged SRE workers", () => {
    const config = fs.readFileSync(configPath, "utf8");
    assert.match(config, /file:\/\/\/__paper_rss_mathjax__/);
    assert.match(config, /enableSpeech:\s*false/);
    assert.match(config, /enableBraille:\s*false/);
    assert.match(config, /enrich:\s*false/);
    assert.match(config, /font:\s*['"]mathjax-tex['"]/);
    assert.ok(!/https?:\/\//.test(config), "MathJax configuration must not introduce a remote runtime path");
  });

  it("MathJax bundle does not contain dynamic remote CDN loading endpoints", () => {
    const scriptText = fs.readFileSync(scriptPath, "utf8");
    assert.ok(!scriptText.includes("cdn.jsdelivr.net/npm/mathjax"), "Must not contain jsdelivr CDN endpoint");
    assert.ok(!scriptText.includes("cdnjs.cloudflare.com/ajax/libs/mathjax"), "Must not contain cdnjs endpoint");
    assert.ok(!scriptText.includes("unpkg.com/mathjax"), "Must not contain unpkg endpoint");
  });

  it("MathJax 4.1.2 bundle is a self-contained offline component", () => {
    const scriptText = fs.readFileSync(scriptPath, "utf8");
    assert.ok(scriptText.length > 2_200_000, "MathJax TeX-font combined bundle must be full standalone bundle");
    assert.ok(scriptText.includes("MathJax"), "Bundle must define MathJax namespace");
  });

  it("Reader installs and removes MathJax per article navigation", () => {
    const source = fs.readFileSync(readerSourcePath, "utf8");
    const macOSStart = source.indexOf("private struct ArticleHTMLView: NSViewRepresentable");
    const macOSCoordinator = source.slice(
      macOSStart,
      source.indexOf("#if os(iOS)", macOSStart)
    );
    const iOSCoordinator = source.slice(
      source.indexOf("private struct ArticleHTMLView: UIViewRepresentable")
    );
    const sharedRuntimeStart = source.indexOf("static func synchronizeMathScripts");
    const sharedRuntimeEnd = source.indexOf("static func isSameDocumentAnchor", sharedRuntimeStart);
    const sharedRuntime = source.slice(sharedRuntimeStart, sharedRuntimeEnd);

    assert.match(sharedRuntime, /removeAllUserScripts/);
    assert.match(sharedRuntime, /addUserScript/);

    for (const coordinator of [macOSCoordinator, iOSCoordinator]) {
      assert.match(coordinator, /synchronizeMathScripts\(in webView: WKWebView\)/);
      assert.match(coordinator, /PaperReaderBridge\.synchronizeMathScripts\(/);
      assert.match(coordinator, /parent\.features\.containsMath/);
    }

    // TeX 运行时必须经导航完成后的原生求值注入（不受页面 CSP 与
    // user script 体量限制影响），不得再作为 WKUserScript 注入。
    const factoryStart = source.indexOf("static func mathUserScripts");
    const factoryEnd = source.indexOf("static func installStandardUserScripts", factoryStart);
    const userScriptFactory = source.slice(factoryStart, factoryEnd);
    assert.ok(!userScriptFactory.includes("loadMathJaxBundleSource"), "mathUserScripts 不得注入 MathJax bundle");

    const injectorStart = source.indexOf("static func injectMathJaxRuntime(in webView: WKWebView) async throws");
    const injectorEnd = source.indexOf("static func isSameDocumentAnchor", injectorStart);
    const injector = source.slice(injectorStart, injectorEnd);
    assert.ok(injectorStart >= 0, "Bridge 必须提供共享的异步 MathJax 注入器");
    assert.match(injector, /loadMathJaxConfigSource\(\)/);
    assert.match(injector, /evaluateJavaScript\(configSource\)/);
    assert.match(injector, /evaluateJavaScript\(runtimeSource\)/);
    assert.match(injector, /MathJax\?\.startup\?\.promise/);
    assert.match(injector, /await startup/);
    assert.match(injector, /querySelectorAll\(['"]mjx-container['"]\)/);
    assert.match(injector, /contentWorld:\s*\.page/);

    for (const coordinator of [macOSCoordinator, iOSCoordinator]) {
      assert.match(coordinator, /injectMathJaxRuntimeIfNeeded\(in: webView\)/);
      assert.match(coordinator, /PaperReaderBridge\.injectMathJaxRuntime\(in: webView\)/);
      assert.match(coordinator, /mathInjectionAttempts/);
      assert.match(coordinator, /lastMathInjectionKey = injectionKey/);
    }
  });

  it("Math typesetting announces a layout refresh consumed by the reader observer", () => {
    const source = fs.readFileSync(readerSourcePath, "utf8");
    assert.match(source, /paperRssLayoutRefresh/);
    assert.match(source, /addEventListener\(\s*["']paperRssLayoutRefresh["']/);
    assert.match(source, /paperRssTOCRail\?\.refresh/);
  });
});
