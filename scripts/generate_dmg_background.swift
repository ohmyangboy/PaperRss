import AppKit

let width: CGFloat = 660
let height: CGFloat = 440
let scale: CGFloat = 2.0

let size = NSSize(width: width * scale, height: height * scale)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Failed to get CGContext")
}

context.scaleBy(x: scale, y: scale)

// Flip Y coordinates so (0,0) is top-left
context.translateBy(x: 0, y: height)
context.scaleBy(x: 1.0, y: -1.0)

// 1. Draw Background Gradient (Soft paper tone)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.97, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.94, green: 0.93, blue: 0.90, alpha: 1.0).cgColor
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
}

// Helper to draw text in flipped coordinates
func drawText(_ text: String, font: NSFont, color: NSColor, at rect: CGRect, alignment: NSTextAlignment = .left) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = alignment
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    
    context.saveGState()
    context.translateBy(x: rect.origin.x, y: rect.origin.y + rect.size.height)
    context.scaleBy(x: 1.0, y: -1.0)
    attrStr.draw(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    context.restoreGState()
}

// Helper to draw rounded rectangle path
func createRoundedRectPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

// 2. Drag Arrow & "按住拖拽安装" Badge
// App icon center: X=175, Y=120. Applications icon center: X=485, Y=120.

// Curved dashed drag arrow from (235, 120) to (420, 120)
context.saveGState()
context.setLineWidth(2.5)
context.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.35, alpha: 0.75).cgColor)
context.setLineDash(phase: 0, lengths: [6, 4])

let arrowPath = CGMutablePath()
arrowPath.move(to: CGPoint(x: 235, y: 120))
arrowPath.addQuadCurve(to: CGPoint(x: 420, y: 120), control: CGPoint(x: 327, y: 82))
context.addPath(arrowPath)
context.strokePath()
context.restoreGState()

// Arrowhead at (420, 120)
context.saveGState()
context.setFillColor(NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.35, alpha: 0.9).cgColor)
let headPath = CGMutablePath()
headPath.move(to: CGPoint(x: 423, y: 120))
headPath.addLine(to: CGPoint(x: 410, y: 112))
headPath.addLine(to: CGPoint(x: 413, y: 120))
headPath.addLine(to: CGPoint(x: 410, y: 128))
headPath.closeSubpath()
context.addPath(headPath)
context.fillPath()
context.restoreGState()

// "按住拖拽安装" Badge Pill
let pillRect = CGRect(x: 250, y: 64, width: 155, height: 28)
let pillPath = createRoundedRectPath(in: pillRect, cornerRadius: 14)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.12).cgColor)
context.setFillColor(NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.24, alpha: 0.95).cgColor)
context.addPath(pillPath)
context.fillPath()
context.restoreGState()

let badgeFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
drawText("按住拖拽安装 ➔", font: badgeFont, color: .white, at: CGRect(x: 250, y: 69, width: 155, height: 20), alignment: .center)


// 3. Bottom Beta Notice Card
let cardRect = CGRect(x: 36, y: 205, width: 588, height: 205)
let cardPath = createRoundedRectPath(in: cardRect, cornerRadius: 12)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: NSColor.black.withAlphaComponent(0.08).cgColor)
context.setFillColor(NSColor.white.cgColor)
context.addPath(cardPath)
context.fillPath()
context.restoreGState()

// Border for Card
context.saveGState()
context.setLineWidth(1.0)
context.setStrokeColor(NSColor(calibratedRed: 0.86, green: 0.84, blue: 0.80, alpha: 1.0).cgColor)
context.addPath(cardPath)
context.strokePath()
context.restoreGState()

// Text inside Card
let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
let bodyFont = NSFont.systemFont(ofSize: 11, weight: .regular)
let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)

let titleColor = NSColor(calibratedRed: 0.80, green: 0.22, blue: 0.18, alpha: 1.0)
let textColor = NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)

drawText("⚠️ 当前为个人 Beta 版本，打开若提示“已损坏”或“无法打开”：", font: titleFont, color: titleColor, at: CGRect(x: 52, y: 220, width: 556, height: 20))

drawText("1. 方法一：请在点击完成后，到系统隐私与安全>安全性中选择仍要打开即可；", font: bodyFont, color: textColor, at: CGRect(x: 52, y: 248, width: 556, height: 18))

drawText("2. 方法二：或者请在终端执行以下清除隔离标记命令：", font: bodyFont, color: textColor, at: CGRect(x: 52, y: 272, width: 556, height: 18))

// Code Block Box
let codeBoxRect = CGRect(x: 52, y: 298, width: 556, height: 96)
let codeBoxPath = createRoundedRectPath(in: codeBoxRect, cornerRadius: 8)

context.saveGState()
context.setFillColor(NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.21, alpha: 1.0).cgColor)
context.addPath(codeBoxPath)
context.fillPath()
context.restoreGState()

// Code text label & code
let codeLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
drawText("TERMINAL COMMAND", font: codeLabelFont, color: NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.68, alpha: 1.0), at: CGRect(x: 64, y: 308, width: 532, height: 14))

let codeColor = NSColor(calibratedRed: 0.50, green: 0.82, blue: 0.60, alpha: 1.0)
drawText("sudo xattr -rd com.apple.quarantine /Applications/PaperRss.app", font: monoFont, color: codeColor, at: CGRect(x: 64, y: 330, width: 532, height: 40))

image.unlockFocus()

// Save PNG to assets/dmg-background.png
guard let tiffData = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData),
      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to convert image to PNG")
}

let fileManager = FileManager.default
let assetsDir = URL(fileURLWithPath: "assets")
try? fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)

let outputURL = URL(fileURLWithPath: "assets/dmg-background.png")
try pngData.write(to: outputURL)
print("Successfully generated DMG background image at \(outputURL.path)")
