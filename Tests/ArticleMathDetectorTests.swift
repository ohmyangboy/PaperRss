import XCTest
import Foundation
@testable import PaperRssCore

final class ArticleMathDetectorTests: XCTestCase {

    let defaultFeedID = UUID()

    // MARK: - 1. TeX Delimiters Detection

    func testDetectsInlineAndBlockTeXDelimiters() {
        let text1 = #"Einstein showed that \(E = mc^2\) is fundamental."#
        XCTAssertTrue(ArticleMathDetector.containsMath(in: text1))

        let text2 = #"The gaussian integral is:\n\[ \int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi} \]"#
        XCTAssertTrue(ArticleMathDetector.containsMath(in: text2))

        let text3 = #"Double dollars equation: $$\sum_{i=1}^n i = \frac{n(n+1)}{2}$$"#
        XCTAssertTrue(ArticleMathDetector.containsMath(in: text3))
    }

    // MARK: - 2. MathML Detection

    func testDetectsMathMLTags() {
        let mathML = #"<p>Here is an equation: <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi><mo>+</mo><mi>y</mi></math></p>"#
        XCTAssertTrue(ArticleMathDetector.containsMath(in: mathML))
    }

    // MARK: - 3. Trusted Inline Dollar Sign vs Currency Price

    func testDifferentiatesInlineMathFromPricesAndCurrency() {
        let mathDollar = #"Let $f(x) = x^2 + 2x + 1$ be a polynomial."#
        XCTAssertTrue(ArticleMathDetector.containsMath(in: mathDollar))

        let singleSymbol = #"The notation $L$ means the number of labels."#
        XCTAssertTrue(ArticleMathDetector.containsMath(in: singleSymbol), "单字母变量也是可信的行内公式")

        let singlePrice = "The subscription costs $9.99 per month or $99 per year."
        XCTAssertFalse(ArticleMathDetector.containsMath(in: singlePrice), "普通货币价格绝不能被误判为公式")

        let rangePrice = "Expected revenue is between $50 and $100 million."
        XCTAssertFalse(ArticleMathDetector.containsMath(in: rangePrice), "价格区间绝不能被误判为公式")

        let escapedPrice = #"Escaped symbol: \$100 is not math."#
        XCTAssertFalse(ArticleMathDetector.containsMath(in: escapedPrice), "转义美元符绝不能被误判为公式")
    }

    // MARK: - 4. Code Blocks Exclusion

    func testIgnoresShellVariablesInsideCodeBlocks() {
        let codeSnippet = """
        <p>Run the following command:</p>
        <pre><code>export PATH=$PATH:$HOME/bin
        echo "Value: $VAR"</code></pre>
        """
        XCTAssertFalse(ArticleMathDetector.containsMath(in: codeSnippet), "代码块内的 shell 变量绝不能被误判为公式")
    }

    // MARK: - 5. PreparedArticle Integration

    func testPreparedArticleAccuratelyFlagsContainsMath() async {
        let fullMathHTML = """
        <div class="article-body">
          <p>This is a complete feed article about electromagnetism.</p>
          <p>We analyze the Maxwell-Ampère law with Maxwell's addition:</p>
          <p>\\(\\nabla \\times \\mathbf{B} = \\mu_0 \\left( \\mathbf{J} + \\varepsilon_0 \\frac{\\partial \\mathbf{E}}{\\partial t} \\right)\\)</p>
          <p>This represents the foundational displacement current density.</p>
        </div>
        """
        let entry = Entry(
            id: "math-entry-1",
            feedID: defaultFeedID,
            title: "Math Article",
            url: URL(string: "https://example.com/math"),
            publishedAt: .now,
            summary: "A brief post about Maxwell equations.",
            contentHTML: fullMathHTML
        )

        let engine = ArticlePreparationEngine()
        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)
        XCTAssertTrue(prepared.features.containsMath)
        XCTAssertEqual(prepared.source, .feed)
    }

    func testNonMathArticleFlagsContainsMathFalse() async {
        let fullPlainHTML = """
        <div class="article-body">
          <p>Today Apple announced several new devices during the special keynote.</p>
          <p>The base tier starts at $999 and the pro tier starts at $1199.</p>
          <p>Preorders begin Friday with global availability next month.</p>
        </div>
        """
        let entry = Entry(
            id: "plain-entry-1",
            feedID: defaultFeedID,
            title: "Normal Tech News",
            url: URL(string: "https://example.com/tech"),
            publishedAt: .now,
            summary: "Today Apple announced new devices priced at $999 and $1199.",
            contentHTML: fullPlainHTML
        )

        let engine = ArticlePreparationEngine()
        let (prepared, _) = await engine.prepare(entry: entry, cached: nil)
        XCTAssertFalse(prepared.features.containsMath)
        XCTAssertEqual(prepared.source, .feed)
    }

    func testPreparedArticlePreservesAndDetectsMathML() async {
        let mathML = """
        <div class="article-body">
          <p>MathML should survive the complete preparation pipeline.</p>
          <math xmlns="http://www.w3.org/1998/Math/MathML" display="block" onload="alert(1)">
            <semantics>
              <mfrac><mi>x</mi><mn>2</mn></mfrac>
              <annotation encoding="application/x-tex">\\frac{x}{2}</annotation>
            </semantics>
          </math>
        </div>
        """
        let entry = Entry(
            id: "mathml-entry",
            feedID: defaultFeedID,
            title: "MathML Article",
            url: nil,
            publishedAt: .now,
            summary: "",
            contentHTML: mathML
        )

        let (prepared, _) = await ArticlePreparationEngine().prepare(entry: entry, cached: nil)

        XCTAssertTrue(prepared.features.containsMath)
        XCTAssertTrue(prepared.html.contains("<math display=\"block\">"))
        XCTAssertTrue(prepared.html.contains("<mfrac><mi>x</mi><mn>2</mn></mfrac>"))
        XCTAssertTrue(prepared.html.contains("<annotation encoding=\"application/x-tex\">\\frac{x}{2}</annotation>"))
        XCTAssertFalse(prepared.html.contains("onload"), "MathML 仍必须经过属性白名单清洗")
    }

    func testPreparedArticleDoesNotDetectMathInsideCodeBlock() async {
        let entry = Entry(
            id: "code-only-math",
            feedID: defaultFeedID,
            title: "Code Example",
            url: nil,
            publishedAt: .now,
            summary: "",
            contentHTML: "<pre><code>const template = `$$x$$`;</code></pre>"
        )

        let (prepared, _) = await ArticlePreparationEngine().prepare(entry: entry, cached: nil)

        XCTAssertFalse(prepared.features.containsMath, "代码块中的定界符不得触发 MathJax")
    }
}
