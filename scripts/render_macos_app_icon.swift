#!/usr/bin/env swift

import AppKit
import SwiftUI

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift render_macos_app_icon.swift <source.png> <output.png>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to read source image: \(sourceURL.path)\n", stderr)
    exit(1)
}

let canvasSize = 1024
let contentInset: CGFloat = 100
let contentSize: CGFloat = 824
let cornerRadius: CGFloat = 185
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
let context = graphicsContext.cgContext
context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
context.interpolationQuality = .high

let contentRect = CGRect(
    x: contentInset,
    y: contentInset,
    width: contentSize,
    height: contentSize
)
let continuousShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
context.addPath(continuousShape.path(in: contentRect).cgPath)
context.clip()
sourceImage.draw(
    in: contentRect,
    from: NSRect(origin: .zero, size: sourceImage.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon PNG\n", stderr)
    exit(1)
}
try pngData.write(to: outputURL, options: .atomic)
