import AppKit
import SwiftUI
import XCTest
@testable import PaperRssDesktop

@MainActor
final class MagazineFoldEffectTests: XCTestCase {
    func testForwardTurnMovesOldRightToNewLeftWithoutMirroring() {
        let geometry = MagazineTurnGeometry(forward: true)
        XCTAssertFalse(geometry.sourceIsLeft)
        XCTAssertTrue(geometry.destinationIsLeft)
        XCTAssertEqual(geometry.anchorX, 0)
        XCTAssertEqual(geometry.finalAngle, -.pi)
        let crease: CGFloat = 550
        // The right outer edge lands exactly on the left outer edge.
        XCTAssertEqual(crease + crease * cos(geometry.finalAngle), 0, accuracy: 0.001)
        XCTAssertEqual(cos(geometry.finalAngle + .pi), 1, accuracy: 0.001)
    }

    func testBackwardTurnReversesTheSameLeaf() {
        let geometry = MagazineTurnGeometry(forward: false)
        XCTAssertTrue(geometry.sourceIsLeft)
        XCTAssertFalse(geometry.destinationIsLeft)
        XCTAssertEqual(geometry.anchorX, 1)
        XCTAssertEqual(geometry.finalAngle, .pi)
        let crease: CGFloat = 550
        XCTAssertEqual(crease - crease * cos(geometry.finalAngle), 1100, accuracy: 0.001)
        XCTAssertEqual(cos(geometry.finalAngle + .pi), 1, accuracy: 0.001)
    }

    func testOddPixelSnapshotHalvesHaveNoLostSeam() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1101, height: 201,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let left = try XCTUnwrap(MagazineTurnGeometry.crop(image, left: true))
        let right = try XCTUnwrap(MagazineTurnGeometry.crop(image, left: false))
        XCTAssertEqual(left.width + right.width, image.width)
        XCTAssertEqual(left.width, 550)
        XCTAssertEqual(right.width, 551)
        XCTAssertEqual(left.height, image.height)
        XCTAssertEqual(right.height, image.height)
    }

    func testSnapshotBudgetIsBoundedAtRetinaAndTallViewportSizes() {
        for size in [CGSize(width: 1100, height: 800), CGSize(width: 1100, height: 3000), CGSize(width: 400, height: 400)] {
            let scale = MagazineTurnGeometry.snapshotScale(size: size, displayScale: 3)
            XCTAssertGreaterThan(scale, 0)
            XCTAssertLessThanOrEqual(scale, 2)
            XCTAssertLessThanOrEqual(size.width * scale * size.height * scale, 3_000_001)
        }
    }

    func testNormalContentUpdatesNeverCaptureOrAnimate() {
        let surface = MagazineTurnSurface(content: Text("Page 1"), pageID: "page-1")
        surface.frame = CGRect(x: 0, y: 0, width: 1100, height: 700)
        for _ in 0..<100 {
            surface.update(content: Text("Page 1"), pageID: "page-1", request: nil,
                reduceMotion: false, isActive: true, background: .white, onComplete: { _ in })
        }
        XCTAssertEqual(surface.snapshotCount, 0)
        XCTAssertFalse(surface.isAnimating)
        surface.cancelTurn()
        XCTAssertFalse(surface.isAnimating)
    }

    func testNoWindowFallsBackAndReleasesNavigationLock() async {
        let surface = MagazineTurnSurface(content: Text("Page 1"), pageID: "page-1")
        let request = MagazinePageTurnRequest(targetPageID: "page-2", forward: true)
        var completed: UUID?
        surface.update(content: Text("Page 2"), pageID: "page-2", request: request,
            reduceMotion: false, isActive: true, background: .white, onComplete: { completed = $0 })
        // Completion is intentionally deferred beyond updateNSView, never a
        // synchronous SwiftUI state mutation during a view update.
        for _ in 0..<10 where completed == nil { await Task.yield() }
        XCTAssertEqual(completed, request.id)
        XCTAssertEqual(surface.snapshotCount, 0)
        XCTAssertFalse(surface.isAnimating)
    }
}
