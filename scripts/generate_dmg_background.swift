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
let bgGradient = NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1.0),
                            ending: NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.89, alpha: 1.0))!
bgGradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 270)


// 2. Drag Arrow & "按住拖拽安装" Badge
// Icons center at Y=320 (AppKit Y). App icon X=175, Applications icon X=485.

// Curved dashed drag arrow
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 2.5
let dash: [CGFloat] = [6, 4]
arrowPath.setLineDash(dash, count: 2, phase: 0)

arrowPath.move(to: NSPoint(x: 235, y: 320))
arrowPath.curve(to: NSPoint(x: 420, y: 320), controlPoint1: NSPoint(x: 280, y: 350), controlPoint2: NSPoint(x: 370, y: 350))

NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.35, alpha: 0.75).setStroke()
arrowPath.stroke()

// Arrowhead at (420, 320)
let headPath = NSBezierPath()
headPath.move(to: NSPoint(x: 423, y: 320))
headPath.line(to: NSPoint(x: 410, y: 328))
headPath.line(to: NSPoint(x: 413, y: 320))
headPath.line(to: NSPoint(x: 410, y: 312))
headPath.close()

NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.35, alpha: 0.9).setFill()
headPath.fill()

// "按住拖拽安装" Badge Pill (Center X=330, Y=366, Width=150, Height=28)
let pillRect = NSRect(x: 255, y: 364, width: 150, height: 28)
let pillPath = createRoundedRectPath(in: pillRect, cornerRadius: 14)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -2)
shadow.shadowBlurRadius = 6
shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
shadow.set()

NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.24, alpha: 0.95).setFill()
pillPath.fill()
NSGraphicsContext.restoreGraphicsState()

let badgeFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
drawText("按住拖拽安装 ➔", font: badgeFont, color: .white, at: NSRect(x: 255, y: 369, width: 150, height: 20), alignment: .center)


// 3. Bottom Beta Notice Card (Width=580, Height=195, Left=40, Bottom Y=25)
let cardRect = NSRect(x: 40, y: 25, width: 580, height: 195)
let cardPath = createRoundedRectPath(in: cardRect, cornerRadius: 12)

NSGraphicsContext.saveGraphicsState()
let cardShadow = NSShadow()
cardShadow.shadowOffset = NSSize(width: 0, height: -4)
cardShadow.shadowBlurRadius = 10
cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
cardShadow.set()

NSColor.white.setFill()
cardPath.fill()
NSGraphicsContext.restoreGraphicsState()

// Stroke for Card
NSColor(calibratedRed: 0.86, green: 0.84, blue: 0.80, alpha: 1.0).setStroke()
cardPath.lineWidth = 1.0
cardPath.stroke()

// Text inside Card
let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
let bodyFont = NSFont.systemFont(ofSize: 11, weight: .regular)
let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)

let titleColor = NSColor(calibratedRed: 0.80, green: 0.22, blue: 0.18, alpha: 1.0)
let textColor = NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)

drawText("⚠️ 当前为个人 Beta 版本，打开若提示“已损坏”或“无法打开”：", font: titleFont, color: titleColor, at: NSRect(x: 56, y: 186, width: 548, height: 20))

drawText("1. 方法一：请在点击完成后，到系统隐私与安全>安全性中选择仍要打开即可；", font: bodyFont, color: textColor, at: NSRect(x: 56, y: 160, width: 548, height: 18))

drawText("2. 方法二：或者请在终端执行以下清除隔离标记命令：", font: bodyFont, color: textColor, at: NSRect(x: 56, y: 136, width: 548, height: 18))

// Code Block Box (Bottom Y = 36, Height = 90)
let codeBoxRect = NSRect(x: 56, y: 36, width: 548, height: 90)
let codeBoxPath = createRoundedRectPath(in: codeBoxRect, cornerRadius: 8)

NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.21, alpha: 1.0).setFill()
codeBoxPath.fill()

// Code text label & code
let codeLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
drawText("TERMINAL COMMAND", font: codeLabelFont, color: NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.68, alpha: 1.0), at: NSRect(x: 68, y: 98, width: 524, height: 14))

let codeColor = NSColor(calibratedRed: 0.50, green: 0.82, blue: 0.60, alpha: 1.0)
drawText("sudo xattr -rd com.apple.quarantine /Applications/PaperRss.app", font: monoFont, color: codeColor, at: NSRect(x: 68, y: 60, width: 524, height: 24))

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
