import SwiftUI

/// 基于 PaperRss App 图标特征（撕纸大写字母 P、印刷十字准星）设计的扁平线条品牌图标。
public struct PaperBrandIcon: View {
    public var size: CGFloat
    public var strokeWidth: CGFloat
    public var primaryColor: Color?
    public var accentColor: Color?

    public init(
        size: CGFloat = 72,
        strokeWidth: CGFloat = 2.2,
        primaryColor: Color? = nil,
        accentColor: Color? = nil
    ) {
        self.size = size
        self.strokeWidth = strokeWidth
        self.primaryColor = primaryColor
        self.accentColor = accentColor
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        Canvas { context, canvasSize in
            let baseScale = min(canvasSize.width, canvasSize.height) / 100.0
            let effectiveLineWidth = strokeWidth * baseScale
            let strokeStyle = StrokeStyle(
                lineWidth: effectiveLineWidth,
                lineCap: .round,
                lineJoin: .round
            )

            let mainColor = primaryColor ?? (colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.38))
            let crossColor = accentColor ?? (PaperTheme.warmAccent.opacity(colorScheme == .dark ? 0.75 : 0.65))

            // 1. 上半部撕裂 "P" 轮廓 (Top Piece)
            var topPiece = Path()
            // 顶部外沿
            topPiece.move(to: CGPoint(x: 26 * baseScale, y: 32.5 * baseScale))
            topPiece.addLine(to: CGPoint(x: 26 * baseScale, y: 17 * baseScale))
            topPiece.addQuadCurve(
                to: CGPoint(x: 29 * baseScale, y: 14 * baseScale),
                control: CGPoint(x: 26 * baseScale, y: 14 * baseScale)
            )
            topPiece.addLine(to: CGPoint(x: 58 * baseScale, y: 14 * baseScale))
            // 顶部右上圆弧转折
            topPiece.addCurve(
                to: CGPoint(x: 74 * baseScale, y: 32.5 * baseScale),
                control1: CGPoint(x: 68 * baseScale, y: 14 * baseScale),
                control2: CGPoint(x: 74 * baseScale, y: 22 * baseScale)
            )
            // 沿撕裂锯齿折线往左
            topPiece.addLine(to: CGPoint(x: 67 * baseScale, y: 30.5 * baseScale))
            topPiece.addLine(to: CGPoint(x: 60 * baseScale, y: 33 * baseScale))
            topPiece.addLine(to: CGPoint(x: 52 * baseScale, y: 31 * baseScale))
            topPiece.addLine(to: CGPoint(x: 43 * baseScale, y: 33.5 * baseScale))
            topPiece.addLine(to: CGPoint(x: 35 * baseScale, y: 31 * baseScale))
            topPiece.addLine(to: CGPoint(x: 26 * baseScale, y: 32.5 * baseScale))
            topPiece.closeSubpath()

            context.stroke(topPiece, with: .color(mainColor), style: strokeStyle)

            // 上孔径 (Upper Inner Counter of P)
            var topCounter = Path()
            topCounter.move(to: CGPoint(x: 43 * baseScale, y: 33.5 * baseScale))
            topCounter.addLine(to: CGPoint(x: 43 * baseScale, y: 26 * baseScale))
            topCounter.addLine(to: CGPoint(x: 55 * baseScale, y: 26 * baseScale))
            topCounter.addQuadCurve(
                to: CGPoint(x: 60 * baseScale, y: 33 * baseScale),
                control: CGPoint(x: 59 * baseScale, y: 26 * baseScale)
            )
            context.stroke(topCounter, with: .color(mainColor), style: strokeStyle)

            // 2. 下半部撕裂 "P" 轮廓 (Bottom Piece)
            var bottomPiece = Path()
            // 从左侧下端裂口开始
            bottomPiece.move(to: CGPoint(x: 26 * baseScale, y: 37.5 * baseScale))
            // 下沿撕裂锯齿折线向右
            bottomPiece.addLine(to: CGPoint(x: 35 * baseScale, y: 36 * baseScale))
            bottomPiece.addLine(to: CGPoint(x: 43 * baseScale, y: 38.5 * baseScale))
            bottomPiece.addLine(to: CGPoint(x: 52 * baseScale, y: 36 * baseScale))
            bottomPiece.addLine(to: CGPoint(x: 60 * baseScale, y: 38 * baseScale))
            bottomPiece.addLine(to: CGPoint(x: 67 * baseScale, y: 35.5 * baseScale))
            bottomPiece.addLine(to: CGPoint(x: 74 * baseScale, y: 37.5 * baseScale))
            // 沿外弧向左下收拢
            bottomPiece.addCurve(
                to: CGPoint(x: 58 * baseScale, y: 53 * baseScale),
                control1: CGPoint(x: 74 * baseScale, y: 45 * baseScale),
                control2: CGPoint(x: 68 * baseScale, y: 53 * baseScale)
            )
            // 连接回竖干
            bottomPiece.addLine(to: CGPoint(x: 43 * baseScale, y: 53 * baseScale))
            // 竖干右侧垂直向下到底部
            bottomPiece.addLine(to: CGPoint(x: 43 * baseScale, y: 83 * baseScale))
            bottomPiece.addQuadCurve(
                to: CGPoint(x: 40 * baseScale, y: 86 * baseScale),
                control: CGPoint(x: 43 * baseScale, y: 86 * baseScale)
            )
            bottomPiece.addLine(to: CGPoint(x: 29 * baseScale, y: 86 * baseScale))
            bottomPiece.addQuadCurve(
                to: CGPoint(x: 26 * baseScale, y: 83 * baseScale),
                control: CGPoint(x: 26 * baseScale, y: 86 * baseScale)
            )
            // 竖干左外沿垂直向上回到撕裂口
            bottomPiece.addLine(to: CGPoint(x: 26 * baseScale, y: 37.5 * baseScale))
            bottomPiece.closeSubpath()

            context.stroke(bottomPiece, with: .color(mainColor), style: strokeStyle)

            // 下孔径 (Lower Inner Counter of P)
            var bottomCounter = Path()
            bottomCounter.move(to: CGPoint(x: 43 * baseScale, y: 38.5 * baseScale))
            bottomCounter.addLine(to: CGPoint(x: 43 * baseScale, y: 41 * baseScale))
            bottomCounter.addLine(to: CGPoint(x: 55 * baseScale, y: 41 * baseScale))
            bottomCounter.addQuadCurve(
                to: CGPoint(x: 60 * baseScale, y: 38 * baseScale),
                control: CGPoint(x: 59 * baseScale, y: 41 * baseScale)
            )
            context.stroke(bottomCounter, with: .color(mainColor), style: strokeStyle)

            // 3. 撕裂处的微弱纸张纤维/折线层次 (Tear Fiber Details)
            var fiberLines = Path()
            fiberLines.move(to: CGPoint(x: 32 * baseScale, y: 33.5 * baseScale))
            fiberLines.addLine(to: CGPoint(x: 30 * baseScale, y: 36.5 * baseScale))
            fiberLines.move(to: CGPoint(x: 48 * baseScale, y: 33.0 * baseScale))
            fiberLines.addLine(to: CGPoint(x: 46 * baseScale, y: 36.0 * baseScale))
            fiberLines.move(to: CGPoint(x: 63 * baseScale, y: 32.5 * baseScale))
            fiberLines.addLine(to: CGPoint(x: 65 * baseScale, y: 35.5 * baseScale))

            let fiberStyle = StrokeStyle(
                lineWidth: max(1.0, effectiveLineWidth * 0.55),
                lineCap: .round,
                dash: [2 * baseScale, 2 * baseScale]
            )
            context.stroke(fiberLines, with: .color(mainColor.opacity(0.55)), style: fiberStyle)

            // 4. 印刷十字准星 (Registration Marks)
            let markLineWidth = max(1.0, effectiveLineWidth * 0.45)
            let markStroke = StrokeStyle(lineWidth: markLineWidth, lineCap: .round)

            // 4a. 左下角准星 (Bottom-Left Mark: Center at 11, 89)
            let blCenter = CGPoint(x: 11 * baseScale, y: 89 * baseScale)
            let markRadius: CGFloat = 3.5 * baseScale
            let markArmLength: CGFloat = 6.5 * baseScale

            var blMark = Path()
            blMark.addEllipse(in: CGRect(
                x: blCenter.x - markRadius,
                y: blCenter.y - markRadius,
                width: markRadius * 2,
                height: markRadius * 2
            ))
            blMark.move(to: CGPoint(x: blCenter.x - markArmLength, y: blCenter.y))
            blMark.addLine(to: CGPoint(x: blCenter.x + markArmLength, y: blCenter.y))
            blMark.move(to: CGPoint(x: blCenter.x, y: blCenter.y - markArmLength))
            blMark.addLine(to: CGPoint(x: blCenter.x, y: blCenter.y + markArmLength))

            context.stroke(blMark, with: .color(crossColor), style: markStroke)

            // 4b. 右上角准星 (Top-Right Mark: Center at 89, 11)
            let trCenter = CGPoint(x: 89 * baseScale, y: 11 * baseScale)

            var trMark = Path()
            trMark.addEllipse(in: CGRect(
                x: trCenter.x - markRadius,
                y: trCenter.y - markRadius,
                width: markRadius * 2,
                height: markRadius * 2
            ))
            trMark.move(to: CGPoint(x: trCenter.x - markArmLength, y: trCenter.y))
            trMark.addLine(to: CGPoint(x: trCenter.x + markArmLength, y: trCenter.y))
            trMark.move(to: CGPoint(x: trCenter.x, y: trCenter.y - markArmLength))
            trMark.addLine(to: CGPoint(x: trCenter.x, y: trCenter.y + markArmLength))

            context.stroke(trMark, with: .color(crossColor), style: markStroke)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
