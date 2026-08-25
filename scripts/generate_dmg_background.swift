import AppKit

let width: CGFloat = 660
let height: CGFloat = 440
let scale: CGFloat = 2.0

let pixelWidth = Int(width * scale)
let pixelHeight = Int(height * scale)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Failed to create NSBitmapImageRep")
}

// Set logical point size so Finder maps PNG 1:1 to 660x440 window at 144 DPI Retina
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Failed to create NSGraphicsContext")
}
NSGraphicsContext.current = context

// Helper to draw text using standard AppKit coordinates (Y=0 at bottom)
func drawText(_ text: String, font: NSFont, color: NSColor, at rect: CGRect, alignment: NSTextAlignment = .left) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    attrStr.draw(in: rect)
}

// Helper for rounded rect path
func createRoundedRectPath(in rect: CGRect, cornerRadius: CGFloat) -> NSBezierPath {
    return NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
}

// 1. Draw Background Gradient
let bgGradient = NSGradient(
    starting: NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.89, alpha: 1.0)
)!
bgGradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 270)

// 2. Drag Arrow & Badge
// Icon center Y in Finder = 170 -> AppKit Y = 440 - 170 = 270
// App icon X = 175, Applications icon X = 485

let iconY: CGFloat = 270

// Curved dashed drag arrow
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 2.5
let dash: [CGFloat] = [6, 4]
arrowPath.setLineDash(dash, count: 2, phase: 0)

arrowPath.move(to: NSPoint(x: 235, y: iconY))
arrowPath.curve(to: NSPoint(x: 420, y: iconY), controlPoint1: NSPoint(x: 280, y: iconY + 38), controlPoint2: NSPoint(x: 375, y: iconY + 38))

NSColor(calibratedRed: 0.28, green: 0.42, blue: 0.32, alpha: 0.75).setStroke()
arrowPath.stroke()

// Arrowhead at (420, iconY)
let headPath = NSBezierPath()
headPath.move(to: NSPoint(x: 423, y: iconY))
headPath.line(to: NSPoint(x: 410, y: iconY + 8))
headPath.line(to: NSPoint(x: 413, y: iconY))
headPath.line(to: NSPoint(x: 410, y: iconY - 8))
headPath.close()

NSColor(calibratedRed: 0.28, green: 0.42, blue: 0.32, alpha: 0.9).setFill()
headPath.fill()

// "按住拖拽安装" Badge Pill (Center X=330, Y=iconY + 48 = 318, Width=140, Height=26)
let pillRect = NSRect(x: 260, y: iconY + 48, width: 140, height: 26)
let pillPath = createRoundedRectPath(in: pillRect, cornerRadius: 13)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -2)
shadow.shadowBlurRadius = 5
shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
shadow.set()

NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.22, alpha: 0.95).setFill()
pillPath.fill()
NSGraphicsContext.restoreGraphicsState()

let badgeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
drawText("按住拖拽安装 ➔", font: badgeFont, color: .white, at: NSRect(x: 260, y: iconY + 52, width: 140, height: 18), alignment: .center)

// 3. Bottom Brand Tagline
let taglineFont = NSFont.systemFont(ofSize: 11, weight: .regular)
let taglineColor = NSColor(calibratedRed: 0.50, green: 0.52, blue: 0.50, alpha: 0.85)
drawText("PaperRss · 现代轻量 RSS 阅读器", font: taglineFont, color: taglineColor, at: NSRect(x: 50, y: 36, width: width - 100, height: 18), alignment: .center)

NSGraphicsContext.restoreGraphicsState()

// Save PNG to assets/dmg-background.png
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to convert image to PNG")
}

let fileManager = FileManager.default
let assetsDir = URL(fileURLWithPath: "assets")
try? fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)

let outputURL = URL(fileURLWithPath: "assets/dmg-background.png")
try pngData.write(to: outputURL)
print("Successfully generated DMG background image at \(outputURL.path)")
