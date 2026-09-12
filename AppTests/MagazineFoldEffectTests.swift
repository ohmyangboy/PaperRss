import XCTest
import SwiftUI
@testable import PaperRssDesktop

final class MagazineFoldEffectTests: XCTestCase {
    /// Calling through the protocol (not the concrete getter) catches an
    /// accidentally main-actor-isolated Animatable conformance at compile time.
    private nonisolated static func interpolate<T: Animatable & Sendable>(
        _ original: T, to value: CGFloat
    ) -> T where T.AnimatableData == CGFloat {
        var copy = original
        copy.animatableData = value
        return copy
    }

    @MainActor
    func testAnimationDataRoundTripsThroughNonisolatedProtocol() {
        let original = MagazineFoldEffect(progress: 0, direction: 1)
        let interpolated = Self.interpolate(original, to: 0.5)
        XCTAssertEqual(interpolated.animatableData, 0.5)
        XCTAssertEqual(interpolated.progress, 0.5)
        XCTAssertEqual(interpolated.direction, 1)
        XCTAssertEqual(original.progress, 0)
    }

    @MainActor
    func testInterpolationOffMainActorUsesAnIndependentValue() async {
        let original = MagazineFoldEffect(progress: 0.25, direction: -1)
        // Capture only the Sendable value; dynamic Self in an instance method
        // may capture the non-Sendable XCTestCase fixture on Swift 6 toolchains.
        let result = await Task.detached { @Sendable [original] in
            MagazineFoldEffectTests.interpolate(original, to: 0.75)
        }.value
        XCTAssertEqual(result.animatableData, 0.75)
        XCTAssertEqual(result.direction, -1)
        XCTAssertEqual(original.animatableData, 0.25)
    }

    @MainActor
    func testFoldEndpointsAndDirectionArePreserved() {
        for direction: CGFloat in [-1, 1] {
            let effect = MagazineFoldEffect(progress: 0.5, direction: direction)
            let unfolded = Self.interpolate(effect, to: 0)
            let folded = Self.interpolate(effect, to: 1)
            XCTAssertEqual(unfolded.animatableData, 0)
            XCTAssertEqual(folded.animatableData, 1)
            XCTAssertEqual(unfolded.direction, direction)
            XCTAssertEqual(folded.direction, direction)
        }
    }
}
