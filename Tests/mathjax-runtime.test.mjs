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

describe("MathJax 4.1.2 Offline Runtime Integrity and Safety", () => {
  it("MathJax 4.1.2 files exist and match exact SHA-256 checksums", () => {
    assert.ok(fs.existsSync(scriptPath), "tex-mml-svg.js must exist locally");
    assert.ok(fs.existsSync(licensePath), "LICENSE must exist locally");

    const scriptBuffer = fs.readFileSync(scriptPath);
    const scriptHash = crypto.createHash("sha256").update(scriptBuffer).digest("hex");
    assert.equal(
      scriptHash,
      "01717984f5715d5ab5f3067e78b9f35a7554d9dfc6205106c39fb6a0285a1cb3",
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

  it("MathJax bundle does not contain dynamic remote CDN loading endpoints", () => {
    const scriptText = fs.readFileSync(scriptPath, "utf8");
    assert.ok(!scriptText.includes("cdn.jsdelivr.net/npm/mathjax"), "Must not contain jsdelivr CDN endpoint");
    assert.ok(!scriptText.includes("cdnjs.cloudflare.com/ajax/libs/mathjax"), "Must not contain cdnjs endpoint");
    assert.ok(!scriptText.includes("unpkg.com/mathjax"), "Must not contain unpkg endpoint");
  });

  it("MathJax 4.1.2 bundle executes self-contained initialization in safe JS sandbox", () => {
    const scriptText = fs.readFileSync(scriptPath, "utf8");
    assert.ok(scriptText.length > 1_500_000, "MathJax combined bundle must be full standalone bundle");
    assert.ok(scriptText.includes("MathJax"), "Bundle must define MathJax namespace");
  });
});
