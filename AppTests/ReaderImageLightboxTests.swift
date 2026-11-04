import PaperRssCore
import WebKit
import XCTest
@testable import PaperRssDesktop

@MainActor
final class ReaderImageLightboxTests: XCTestCase, WKNavigationDelegate {
    private var documentLoaded: XCTestExpectation?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentLoaded?.fulfill()
    }

    private func loadImage(width: Int, height: Int, into view: WKWebView) async {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)'><rect width='100%' height='100%' fill='navy'/></svg>"
        let src = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let article = PreparedArticle(text: "Image", html: "<img id='fixture' src='\(src)'>",
            imageURLs: [], baseURL: nil, source: .feed)
        let document = ReaderDocumentRenderer.renderDocument(article: article,
            documentIdentity: "lightbox", topInset: 84, extraStyleCSS: paperArticleStyle)
        let loaded = expectation(description: "Reader image loaded")
        documentLoaded = loaded
        view.navigationDelegate = self
        view.loadHTMLString(document.html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        documentLoaded = nil
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PaperReaderBridge.mediaFullscreenScript)
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    }

    private func evaluate(_ script: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: .defaultClient) {
                continuation.resume(with: $0.map { $0 as? String ?? "" })
            }
        }
    }

    private func assertInitialPreviewFits(in view: WKWebView, context: String) async throws -> CGPoint {
        let result = try await evaluate("""
        (() => {
          const img = document.querySelector('.paper-rss-lightbox-img');
          const image = img.getBoundingClientRect();
          const close = document.querySelector('.paper-rss-lightbox-close').getBoundingClientRect();
          const reservedTop = parseFloat(getComputedStyle(document.body).paddingTop);
          const hit = document.elementFromPoint(close.x + close.width / 2, close.y + close.height / 2);
          return JSON.stringify({ image, close, valid:
            close.top >= reservedTop && close.left >= 0 && close.right <= innerWidth && close.bottom <= innerHeight
            && !!hit?.closest('.paper-rss-lightbox-close')
            && image.left >= 0 && image.right <= innerWidth && image.top >= close.bottom && image.bottom <= innerHeight
            && image.width <= img.naturalWidth + 1 && image.height <= img.naturalHeight + 1
            && Math.abs(image.width / image.height - img.naturalWidth / img.naturalHeight) < 0.01
          });
        })()
        """, in: view)
        let json = result
        let measurement = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(measurement["valid"] as? Bool, true, "\(context): \(json)")
        let close = try XCTUnwrap(measurement["close"] as? [String: Double])
        return CGPoint(x: try XCTUnwrap(close["x"]), y: try XCTUnwrap(close["y"]))
    }

    func testInitialPreviewFitsWithoutMovingCloseButtonWithImageSize() async throws {
        let view = makeWebView()
        defer { view.stopLoading(); view.navigationDelegate = nil }
        var closePosition: CGPoint?
        for (width, height) in [(2400, 3600), (3600, 2400), (800, 10000), (10000, 600), (100, 100)] {
            await loadImage(width: width, height: height, into: view)
            _ = try await evaluate("document.getElementById('fixture').click(); undefined", in: view)
            let position = try await assertInitialPreviewFits(in: view, context: "\(width)x\(height)")
            if let closePosition { XCTAssertEqual(position, closePosition, "Image dimensions must not move the close button") }
            closePosition = position
        }
    }

    func testCloseRemainsClickableAfterZoomDragAndResize() async throws {
        let view = makeWebView()
        defer { view.stopLoading(); view.navigationDelegate = nil }
        await loadImage(width: 2400, height: 3600, into: view)
        let result = try await evaluate("""
        (() => {
          document.getElementById('fixture').click();
          const overlay = document.querySelector('.paper-rss-lightbox');
          const img = overlay.querySelector('img');
          const close = overlay.querySelector('button');
          const before = close.getBoundingClientRect();
          const reachable = () => {
            const r = close.getBoundingClientRect();
            return r.x === before.x && r.y === before.y
              && !!document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)?.closest('.paper-rss-lightbox-close');
          };
          overlay.dispatchEvent(new WheelEvent('wheel', { ctrlKey: true, deltaY: -1000, cancelable: true }));
          const afterZoom = reachable();
          img.dispatchEvent(new MouseEvent('mousedown', { clientX: 200, clientY: 200, bubbles: true }));
          window.dispatchEvent(new MouseEvent('mousemove', { clientX: 1000, clientY: -600 }));
          window.dispatchEvent(new MouseEvent('mouseup'));
          const afterDrag = reachable();
          close.click();
          const buttonClosed = !overlay.classList.contains('is-active');
          document.getElementById('fixture').click();
          window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
          const escapeClosed = !overlay.classList.contains('is-active');
          document.getElementById('fixture').click();
          overlay.querySelector('.paper-rss-lightbox-backdrop').click();
          const backdropClosed = !overlay.classList.contains('is-active');
          document.getElementById('fixture').click();
          document.documentElement.style.setProperty('--paper-font-size', '36px');
          return String(afterZoom && afterDrag && buttonClosed && escapeClosed && backdropClosed);
        })()
        """, in: view)
        XCTAssertEqual(result, "true", "Zoomed or dragged images must not cover the close button; all close actions must work")
        for (width, height) in [(480, 360), (1200, 800)] {
            view.setFrameSize(CGSize(width: width, height: height))
            _ = try await assertInitialPreviewFits(in: view, context: "Resized to \(width)x\(height)")
        }
    }
}
