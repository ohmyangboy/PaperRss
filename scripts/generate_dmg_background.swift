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

// 2. Drag Arrow & "按住拖拽安装" Badge
// Icons center at Y=340 (AppKit Y). App icon X=175, Applications icon X=485.

// Curved dashed drag arrow
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 2.5
let dash: [CGFloat] = [6, 4]
arrowPath.setLineDash(dash, count: 2, phase: 0)

arrowPath.move(to: NSPoint(x: 235, y: 340))
arrowPath.curve(to: NSPoint(x: 420, y: 340), controlPoint1: NSPoint(x: 280, y: 370), controlPoint2: NSPoint(x: 370, y: 370))

NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.35, alpha: 0.75).setStroke()
arrowPath.stroke()

// Arrowhead at (420, 340)
let headPath = NSBezierPath()
headPath.move(to: NSPoint(x: 423, y: 340))
headPath.line(to: NSPoint(x: 410, y: 348))
headPath.line(to: NSPoint(x: 413, y: 340))
headPath.line(to: NSPoint(x: 410, y: 332))
headPath.close()

NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.35, alpha: 0.9).setFill()
headPath.fill()

// "按住拖拽安装" Badge Pill (Center X=330, Y=384, Width=150, Height=26)
let pillRect = NSRect(x: 255, y: 382, width: 150, height: 26)
let pillPath = createRoundedRectPath(in: pillRect, cornerRadius: 13)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -2)
shadow.shadowBlurRadius = 5
shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
shadow.set()

NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.24, alpha: 0.95).setFill()
pillPath.fill()
NSGraphicsContext.restoreGraphicsState()

let badgeFont = NSFont.systemFont(ofSize: 12, weight: .bold)
drawText("按住拖拽安装 ➔", font: badgeFont, color: .white, at: NSRect(x: 255, y: 386, width: 150, height: 18), alignment: .center)


// 3. Install File Hint Label (Above the INSTALL.txt icon)
let helperHintFont = NSFont.systemFont(ofSize: 11, weight: .bold)
let helperHintColor = NSColor(calibratedRed: 0.22, green: 0.45, blue: 0.35, alpha: 1.0)
drawText("▼ 双击 INSTALL.txt 复制命令，粘贴到「终端」回车运行", font: helperHintFont, color: helperHintColor, at: NSRect(x: 130, y: 246, width: 400, height: 16), alignment: .center)


// 4. Bottom Beta Notice Card (Width=590, Height=106, Left=35, Bottom Y=16)
let cardRect = NSRect(x: 35, y: 16, width: 590, height: 106)
let cardPath = createRoundedRectPath(in: cardRect, cornerRadius: 10)

NSGraphicsContext.saveGraphicsState()
let cardShadow = NSShadow()
cardShadow.shadowOffset = NSSize(width: 0, height: -3)
cardShadow.shadowBlurRadius = 8
cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.06)
cardShadow.set()

NSColor.white.setFill()
cardPath.fill()
NSGraphicsContext.restoreGraphicsState()

// Stroke for Card
NSColor(calibratedRed: 0.86, green: 0.84, blue: 0.80, alpha: 1.0).setStroke()
cardPath.lineWidth = 0.8
cardPath.stroke()

// Text inside Card
let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
let stepFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
let subFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)

let titleColor = NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.16, alpha: 1.0)
let textColor = NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)
let subColor = NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)

drawText("⚠️ 打开若提示“已损坏”或“无法打开”（未加入 Apple 付费公证）：", font: titleFont, color: titleColor, at: NSRect(x: 50, y: 96, width: 560, height: 18))

drawText("1. 请先将左侧 PaperRss 拖入 Applications；", font: stepFont, color: textColor, at: NSRect(x: 50, y: 74, width: 560, height: 16))

drawText("2. 打开「终端」(Terminal.app)，将上方 INSTALL.txt 中的命令复制粘贴并回车；", font: stepFont, color: textColor, at: NSRect(x: 50, y: 54, width: 560, height: 16))

drawText("3. 备用：或在「系统设置 > 隐私与安全性」底部点击「仍要打开」", font: subFont, color: subColor, at: NSRect(x: 50, y: 28, width: 560, height: 15))

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
