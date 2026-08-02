import SwiftUI

enum PaperSurfaceKind {
    case page
    case articleList
    case sidebar
}

enum PaperTheme {
    static let accent = Color(red: 0.38, green: 0.45, blue: 0.34)
    static let warmAccent = Color(red: 0.64, green: 0.34, blue: 0.24)

    static func chromeBackground(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.128, green: 0.124, blue: 0.111)
            : Color(red: 0.948, green: 0.938, blue: 0.907)
    }

    static func surface(_ kind: PaperSurfaceKind, scheme: ColorScheme) -> Color {
        switch (kind, scheme) {
        case (.page, .light):
            Color(red: 0.965, green: 0.949, blue: 0.906)
        case (.articleList, .light):
            Color(red: 0.944, green: 0.931, blue: 0.895)
        case (.sidebar, .light):
            Color(red: 0.918, green: 0.910, blue: 0.884)
        case (.page, .dark):
            Color(red: 0.105, green: 0.102, blue: 0.092)
        case (.articleList, .dark):
            Color(red: 0.122, green: 0.118, blue: 0.106)
        case (.sidebar, .dark):
            Color(red: 0.138, green: 0.133, blue: 0.120)
        @unknown default:
            Color(red: 0.5, green: 0.5, blue: 0.5)
        }
    }

    static func grain(scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.028) : .black.opacity(0.026)
    }

    static func fiber(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.72, green: 0.68, blue: 0.58).opacity(0.032)
            : Color(red: 0.42, green: 0.36, blue: 0.26).opacity(0.035)
    }

    static func noteBackground(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.155, green: 0.169, blue: 0.142)
            : Color(red: 0.910, green: 0.902, blue: 0.840)
    }

    static func noteBorder(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.48, green: 0.54, blue: 0.42).opacity(0.42)
            : Color(red: 0.38, green: 0.45, blue: 0.34).opacity(0.28)
    }
}

struct PaperSurface: View {
    let kind: PaperSurfaceKind
    var textureOpacity: Double = 1

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            PaperTheme.surface(kind, scheme: colorScheme)

            LinearGradient(
                colors: colorScheme == .dark
                    ? [.white.opacity(0.018), .clear, .black.opacity(0.035)]
                    : [.white.opacity(0.22), .clear, PaperTheme.warmAccent.opacity(0.018)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            PaperGrain(opacity: textureOpacity)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct PaperGrain: View {
    let opacity: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let area = max(1, size.width * size.height)
            let dotCount = min(720, max(90, Int(area / 2_000)))
            let grain = PaperTheme.grain(scheme: colorScheme).opacity(opacity)
            let fiber = PaperTheme.fiber(scheme: colorScheme).opacity(opacity)

            for index in 0..<dotCount {
                let x = unit(index &* 83 &+ 17, modulus: 997) * size.width
                let y = unit(index &* 191 &+ 43, modulus: 991) * size.height
                let diameter = 0.38 + unit(index &* 47 &+ 11, modulus: 89) * 0.72
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                    with: .color(grain)
                )
            }

            let fiberCount = min(24, max(8, Int(size.height / 70)))
            for index in 0..<fiberCount {
                let y = unit(index &* 127 &+ 31, modulus: 983) * size.height
                let length = 24 + unit(index &* 53 &+ 7, modulus: 97) * 72
                let x = unit(index &* 211 &+ 13, modulus: 977) * max(1, size.width - length)
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addCurve(
                    to: CGPoint(x: x + length, y: y + 0.5),
                    control1: CGPoint(x: x + length * 0.32, y: y - 0.7),
                    control2: CGPoint(x: x + length * 0.68, y: y + 0.9)
                )
                context.stroke(path, with: .color(fiber), lineWidth: 0.42)
            }
        }
        .opacity(opacity)
    }

    private func unit(_ value: Int, modulus: Int) -> CGFloat {
        CGFloat(abs(value % modulus)) / CGFloat(modulus)
    }
}

struct PaperHeaderSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            PaperTheme.surface(.page, scheme: colorScheme).opacity(colorScheme == .dark ? 0.82 : 0.88)
            PaperGrain(opacity: 0.55)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
