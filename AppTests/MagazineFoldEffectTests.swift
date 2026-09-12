import MetalKit
import AppKit
import SwiftUI
import XCTest
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
private final class MagazineLifecycleInput: ObservableObject {
    @Published var key: TimelineKeyRequest?
    @Published var browsing = true
}
private struct MagazineLifecycleDriver<Content: View>: View {
    @ObservedObject var input: MagazineLifecycleInput
    let content: (TimelineKeyRequest?) -> Content
    var body: some View { content(input.key) }
}

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

    func testEnlargedPaperKeepsOnlyTwoLinesOfOuterMargin() {
        for size in [CGSize(width: 900, height: 700), CGSize(width: 1600, height: 1200)] {
            XCTAssertEqual(MagazinePaginator.turnInset(size), 32)
            XCTAssertEqual(MagazinePaginator.foldViewport(size).height, size.height - 64)
        }
        XCTAssertEqual(MagazinePaginator.pageWidth(1600), 1240)
        XCTAssertEqual(MagazinePaginator.pageWidth(900), 804)
    }

    func testNormalContentUpdatesNeverCaptureOrAnimate() {
        let surface = MagazineTurnSurface(content: Text("Page 1"), pageID: "page-1")
        surface.frame = CGRect(x: 0, y: 0, width: 1100, height: 700)
        for _ in 0..<100 {
            surface.update(content: Text("Page 1"), pageID: "page-1", request: nil,
                reduceMotion: false, isActive: true, background: .white, onComplete: { _, _ in })
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
            reduceMotion: false, isActive: true, background: .white, onComplete: { id, _ in completed = id })
        // Completion is intentionally deferred beyond updateNSView, never a
        // synchronous SwiftUI state mutation during a view update.
        for _ in 0..<10 where completed == nil { await Task.yield() }
        XCTAssertEqual(completed, request.id)
        XCTAssertEqual(surface.snapshotCount, 0)
        XCTAssertFalse(surface.isAnimating)
    }

    func testRemountedDestinationReleasesOutstandingRequest() async {
        let surface = MagazineTurnSurface(content: Text("目标页"), pageID: "new")
        let request = MagazinePageTurnRequest(targetPageID: "new", forward: true, progress: 0.8)
        var completed: UUID?
        surface.update(content: Text("目标页"), pageID: "new", request: request,
            reduceMotion: false, isActive: true, background: .white, onComplete: { id, _ in completed = id })
        for _ in 0..<10 where completed == nil { await Task.yield() }
        XCTAssertEqual(completed, request.id)
        XCTAssertFalse(surface.isAnimating)
    }

    func testMagazineBrowserTurnLifecycle() async throws {
        let domain = "magazine-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(MagazineTurning.fold.rawValue, forKey: "magazine_turning")
        defer { defaults.removePersistentDomain(forName: domain) }
        let feed = UUID()
        let entries = (0..<30).map { EntryListItem(id: "e\($0)", feedID: feed, title: "Title \($0)", sourceTitle: "Feed") }
        let memory = TimelinePresentationMemory()
        memory.magazineIsOpen = true
        func root(_ key: TimelineKeyRequest?) -> some View {
            MagazineBrowserView(entries: entries, folders: [:], availableSize: CGSize(width: 1000, height: 800),
                showsImages: false, isBrowsing: true, hasMore: false, selectedID: nil, keyboardRequest: key,
                memory: memory, onHighlight: { _ in }, onOpen: { _ in }, onNeedMore: {},
                tile: { entry, _, _ in Text(entry.title) }).defaultAppStorage(defaults)
        }
        let input = MagazineLifecycleInput()
        let host = NSHostingView(rootView: MagazineLifecycleDriver(input: input, content: root)
            .frame(width: 1000, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let pages = MagazinePaginator.pages(entries: entries, folders: [:], arrangement: .balanced,
            size: MagazinePaginator.foldViewport(CGSize(width: 1000, height: 800)), showsImages: false)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        func containsMetal(_ view: NSView) -> Bool {
            view is MTKView || view.subviews.contains(where: containsMetal)
        }
        for index in 1...2 {
            let sourceAnchor = memory.magazineAnchor
            input.key = TimelineKeyRequest(keyCode: 121)
            for _ in 0..<10 where !containsMetal(host) {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            XCTAssertTrue(containsMetal(host), "目标页和请求必须同时交给快照渲染器")
            XCTAssertEqual(memory.magazineAnchor, sourceAnchor, "动画完成前不能提前保存目标锚点")
            for _ in 0..<45 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            }
            XCTAssertEqual(memory.magazineAnchor, pages[index].page.entries.first?.id)
        }
    }

    func testInteractiveCancellationReleasesSnapshotsAndIgnoresOldCompletion() async throws {
        let surface = MagazineTurnSurface(content: Text("旧页"), pageID: "old")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface; window.orderFront(nil)
        defer { window.close() }
        surface.layoutSubtreeIfNeeded()
        var completions: [(UUID, Bool)] = []
        var request = MagazinePageTurnRequest(targetPageID: "new", forward: true, progress: 0.25)
        surface.update(content: Text("新页"), pageID: "new", request: request, reduceMotion: false,
            isActive: true, background: .white, onComplete: { completions.append(($0, $1)) })
        for _ in 0..<10 { await Task.yield(); surface.layoutSubtreeIfNeeded() }
        XCTAssertEqual(surface.snapshotCount, 2)
        XCTAssertTrue(surface.hitTest(NSPoint(x: 100, y: 100)) is NSHostingView<Text>,
            "快照层必须让鼠标释放回到原手势宿主")
        request.progress = nil; request.commit = false
        surface.update(content: Text("新页"), pageID: "new", request: request, reduceMotion: false,
            isActive: true, background: .white, onComplete: { completions.append(($0, $1)) })
        surface.cancelTurn()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(surface.isAnimating)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.0, request.id)
        XCTAssertEqual(completions.first?.1, false)
        XCTAssertEqual(surface.snapshotCount, 2)
    }
    func testCancelledGestureReturnsToSourceWithoutAnotherSnapshot() async throws {
        let surface = MagazineTurnSurface(content: Text("源页面"), pageID: "source")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface; window.orderFront(nil)
        defer { window.close() }
        surface.layoutSubtreeIfNeeded()
        var request = MagazinePageTurnRequest(targetPageID: "target", forward: true, progress: 0.2)
        var completed: Bool?
        func update() {
            surface.update(content: Text("目标页面"), pageID: "target", request: request,
                reduceMotion: false, isActive: true, background: .white,
                onComplete: { _, committed in completed = committed })
        }
        update()
        for _ in 0..<10 { await Task.yield(); surface.layoutSubtreeIfNeeded() }
        for index in 1...20 { request.progress = Double(index) / 100; update() }
        XCTAssertEqual(surface.snapshotCount, 2, "拖动过程不能重新抓图")
        request.progress = nil; request.commit = false; update()
        for _ in 0..<40 where completed == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(completed, false)
        XCTAssertFalse(surface.isAnimating)
        // 源页面身份已恢复，再从源页翻向目标页必须正常进入新的翻页。
        request = MagazinePageTurnRequest(targetPageID: "target", forward: true, progress: 0.1)
        update()
        XCTAssertTrue(surface.isAnimating)
        surface.cancelTurn(notify: false)
    }

    func testMetalFramesHaveCorrectStationaryHalvesAndExactEndpoints() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 320, height = 200
        func image(_ left: NSColor, _ right: NSColor) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(left.cgColor); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(right.cgColor); context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            // 非对称角标检测上下颠倒与横向镜像。
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 20, y: 20, width: 24, height: 18))
            return try XCTUnwrap(context.makeImage())
        }
        let old = try image(.red, .green), new = try image(.blue, .yellow)
        for forward in [true, false] {
            let renderer = try XCTUnwrap(MagazineMetalRenderer(before: old, after: new,
                size: CGSize(width: width, height: height), forward: forward), "Metal 程序必须实际编译成功")
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var frames: [[UInt8]] = []
            for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(renderer.encode(progress: p, target: texture, buffer: buffer))
                buffer.commit(); buffer.waitUntilCompleted()
                XCTAssertNil(buffer.error)
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                texture.getBytes(&bytes, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                frames.append(bytes)
            }
            func pixel(_ frame: Int, _ x: Int, _ y: Int = 100) -> [UInt8] {
                Array(frames[frame][((y * width + x) * 4)..<((y * width + x) * 4 + 3)])
            }
            XCTAssertEqual(pixel(0, 50), [0, 0, 255])
            XCTAssertEqual(pixel(4, 50), [255, 0, 0])
            XCTAssertEqual(pixel(4, 260), [0, 255, 255])
            XCTAssertEqual(pixel(0, 30, 175), [255, 255, 255])
            XCTAssertEqual(pixel(4, 30, 175), [255, 255, 255])
            if forward {
                XCTAssertEqual(pixel(1, 50), pixel(0, 50))
                XCTAssertEqual(pixel(3, 260), pixel(4, 260))
            } else {
                XCTAssertEqual(pixel(1, 260), pixel(0, 260))
                XCTAssertEqual(pixel(3, 50), pixel(4, 50))
            }
            XCTAssertNotEqual(frames[1], frames[3])
        }
    }

    func testRaisedPageFitsInsideStageAndActuallyUsesVerticalClearance() throws {
        let width = 320, height = 200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for inset in [6, 20] {
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: inset, width: width, height: height - inset * 2))
            let image = try XCTUnwrap(context.makeImage())
            for forward in [true, false] {
            for corner in [Float(0)] + MagazineTurnVariation.presets.map(\.corner) {
            let renderer = try XCTUnwrap(MagazineMetalRenderer(before: image, after: image,
                size: CGSize(width: width, height: height), forward: forward, verticalInset: CGFloat(inset), corner: corner))
            for step in 0...20 {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(renderer.encode(progress: Double(step) / 20, target: target, buffer: buffer))
                buffer.commit(); buffer.waitUntilCompleted()
                XCTAssertNil(buffer.error)
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                target.getBytes(&bytes, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                for y in [0, height - 1] {
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        XCTAssertEqual(Array(bytes[offset..<(offset + 3)]), [255, 0, 0],
                            "整个翻页过程的上下边缘都应保留舞台背景")
                    }
                }
                if step == 5 || step == 15 {
                    XCTAssertTrue((0..<width).contains { bytes[((inset - 2) * width + $0) * 4 + 2] > 100 },
                        "页片应伸入预留空间，不能只缩小内容后继续裁切")
                }
            }
            }
            }
        }
    }

    func testRetinaRenderBudgetReportsGPUFrameTime() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 2200, height = 1360
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let renderer = try XCTUnwrap(MagazineMetalRenderer(before: image, after: image,
            size: CGSize(width: 1100, height: 680), forward: true))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var milliseconds: [Double] = []
        for index in 0..<32 {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encode(progress: Double(index) / 31, target: target, buffer: buffer))
            buffer.commit(); buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            milliseconds.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        milliseconds.sort()
        print("Magazine GPU 2200x1360: median=\(milliseconds[16])ms p95=\(milliseconds[30])ms; excludes capture and display scheduling")
    }

    func testRepeatedMetalDrawsReleaseDrawableAndLeaveWindowResponsive() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 200,
            bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let image = try XCTUnwrap(context.makeImage())
        let renderer = try XCTUnwrap(MagazineMetalRenderer(before: image, after: image,
            size: CGSize(width: 320, height: 200), forward: true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.view; window.orderFront(nil)
        defer { window.close() }
        for index in 0..<60 {
            XCTAssertTrue(renderer.draw(progress: Double(index % 30) / 29))
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThanOrEqual(renderer.frameCount, 60)
        XCTAssertNotNil(window.contentView)
    }

}

extension MagazineFoldEffectTests {
    func testCrossfadeCommitsAndCancelsWithoutAdditionalSnapshots() async throws {
        for commit in [false, true] {
            let surface = MagazineTurnSurface(content: Text("源页"), pageID: "source")
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface; window.orderFront(nil)
            defer { window.close() }
            surface.layoutSubtreeIfNeeded()
            var request = MagazinePageTurnRequest(targetPageID: "target", forward: true, progress: 0.3)
            var completed: Bool?
            func update() {
                surface.update(content: Text("目标页"), pageID: "target", request: request,
                    reduceMotion: false, isActive: true, background: .white, fades: true,
                    onComplete: { _, result in completed = result })
            }
            update()
            for _ in 0..<10 { await Task.yield(); surface.layoutSubtreeIfNeeded() }
            XCTAssertEqual(surface.snapshotCount, 2)
            request.progress = nil; request.commit = commit; update()
            for _ in 0..<40 where completed == nil { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(completed, commit)
            XCTAssertFalse(surface.isAnimating)
            XCTAssertEqual(surface.snapshotCount, 2)
        }
    }
}

extension MagazineFoldEffectTests {
    func testRestorationRequestedWhileHiddenRunsWhenMagazineReappears() async throws {
        let domain = "magazine-return-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set("fold", forKey: "magazine_turning")
        defer { defaults.removePersistentDomain(forName: domain) }
        let entries = (0..<18).map { EntryListItem(id: "return-\($0)", feedID: UUID(), title: "短文章 \($0)", sourceTitle: "来源") }
        let memory = TimelinePresentationMemory()
        memory.magazineIsOpen = true
        let input = MagazineLifecycleInput()
        let host = NSHostingView(rootView: MagazineLifecycleDriver(input: input) { key in
            MagazineBrowserView(entries: entries, folders: [:], availableSize: CGSize(width: 1000, height: 800),
                showsImages: false, isBrowsing: input.browsing, hasMore: false, selectedID: nil, keyboardRequest: key,
                memory: memory, onHighlight: { _ in }, onOpen: { _ in }, onNeedMore: {},
                tile: { entry, _, _ in Text(entry.title) }).defaultAppStorage(defaults)
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        input.browsing = false
        try await Task.sleep(for: .milliseconds(50))
        memory.prepareRestoration(anchor: "return-8")
        try await Task.sleep(for: .milliseconds(150))
        input.browsing = true
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(memory.magazineAnchor, "return-8")
        XCTAssertFalse(memory.isRestoring)
    }
}

extension MagazineFoldEffectTests {
    func testCoverOpensWithoutSelectingAndScopeResetClosesIt() async throws {
        let memory = TimelinePresentationMemory()
        let input = MagazineLifecycleInput()
        var highlighted: String?
        var cleared = 0
        let host = NSHostingView(rootView: MagazineLifecycleDriver(input: input) { key in
            MagazineBrowserView(entries: [], folders: [:], availableSize: CGSize(width: 1000, height: 800),
                showsImages: true, isBrowsing: true, hasMore: false, selectedID: nil, keyboardRequest: key,
                memory: memory, onHighlight: { highlighted = $0 }, onOpen: { _ in XCTFail("封面不能直接打开文章") },
                onNeedMore: {}, coverTitle: "空订阅", onClearSelection: { cleared += 1 },
                tile: { entry, _, _ in Text(entry.title) })
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(memory.magazineIsOpen)
        XCTAssertNil(highlighted)
        input.key = .init(keyCode: 36)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(memory.magazineIsOpen)
        XCTAssertNil(highlighted)
        input.key = .init(keyCode: 53)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(cleared, 1)
        memory.magazineIsOpen = false
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(memory.magazineIsOpen, "手动合上后旧的自动打开任务不能再次触发")
        memory.resetScope()
        XCTAssertFalse(memory.magazineIsOpen)
        XCTAssertNil(memory.magazineAnchor)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(memory.magazineIsOpen, "封面需停留足够时间")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(memory.magazineIsOpen, "新的来源应在一秒后自动展开")
        XCTAssertNil(highlighted)
    }
}

extension MagazineFoldEffectTests {
    func testReleaseCurveRetainsVelocityAndStopsAtTheDestination() {
        let step = 0.00001
        for slope in [-1.0, 0, 0.5, 1, 2, 3] {
            XCTAssertEqual(MagazineTurnGeometry.settled(0, slope: slope), 0)
            XCTAssertEqual(MagazineTurnGeometry.settled(1, slope: slope), 1)
            let initialVelocity = MagazineTurnGeometry.settled(step, slope: slope) / step
            let finalVelocity = (1 - MagazineTurnGeometry.settled(1 - step, slope: slope)) / step
            XCTAssertEqual(initialVelocity, slope, accuracy: 0.001)
            XCTAssertEqual(finalVelocity, 0, accuracy: 0.001)
        }
    }
}
