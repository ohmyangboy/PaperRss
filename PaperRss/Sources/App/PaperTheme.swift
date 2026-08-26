import SwiftUI
#if SWIFT_PACKAGE
import PaperRssCore
#endif

enum PaperSurfaceKind {
    case page
    case articleList
    case sidebar
}

extension ReaderAppearanceMode {
    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

extension Color {
    init(paperHex: String) {
        let raw = paperHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(raw, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct PaperAppearancePaletteKey: EnvironmentKey {
    static let defaultValue = ReaderAppearance.default.palette(for: .light)
}

extension EnvironmentValues {
    var paperAppearancePalette: ReaderAppearancePalette {
        get { self[PaperAppearancePaletteKey.self] }
        set { self[PaperAppearancePaletteKey.self] = newValue }
    }
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

struct AppearanceSurface: View {
    let role: AppearanceSurfaceRole
    let appearance: ReaderAppearance
    let mode: ReaderAppearanceMode
    var textureOpacity: Double = 1

    var body: some View {
        Group {
            if appearance.preset == .paper && !appearance.isCustom {
                PaperSurface(kind: paperSurfaceKind, textureOpacity: textureOpacity)
            } else {
                Color(paperHex: appearance.backgroundHex(for: mode, surface: role))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var paperSurfaceKind: PaperSurfaceKind {
        switch role {
        case .sidebar: .sidebar
        case .articleList: .articleList
        case .reader: .page
        }
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
    var kind: PaperSurfaceKind = .page
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            PaperTheme.surface(kind, scheme: colorScheme).opacity(colorScheme == .dark ? 0.82 : 0.88)
            PaperGrain(opacity: 0.55)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct AppearanceHeaderSurface: View {
    let role: AppearanceSurfaceRole
    let appearance: ReaderAppearance
    let mode: ReaderAppearanceMode

    var body: some View {
        if appearance.preset == .paper && !appearance.isCustom {
            PaperHeaderSurface(kind: paperSurfaceKind)
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(paperHex: appearance.backgroundHex(for: mode, surface: role)).opacity(0.88)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private var paperSurfaceKind: PaperSurfaceKind {
        switch role {
        case .sidebar: .sidebar
        case .articleList: .articleList
        case .reader: .page
        }
    }
}

/// 顶部工具栏渐变玻璃模糊层（Gradient Glass Blur）。
/// 通过对 .ultraThinMaterial 施加垂直平滑渐变遮罩，使内容向上滚动经过顶部工具栏区域时
/// 呈现柔和透明的磨砂渐变融入背景，消除生硬的实色矩形色块与横向截断切线。
struct PaperTopBarBlur: View {
    var height: CGFloat = 52
    var opacity: Double = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black.opacity(0.95), location: 0.20),
                            .init(color: .black.opacity(0.80), location: 0.40),
                            .init(color: .black.opacity(0.50), location: 0.62),
                            .init(color: .black.opacity(0.20), location: 0.82),
                            .init(color: .black.opacity(0.04), location: 0.94),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .frame(height: height)
        .opacity(opacity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PaperEmptyState: View {
    let title: String
    let description: String
    var systemImage: String? = nil
    var showsBrandIcon = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if showsBrandIcon {
                PaperBrandIcon(width: 78)
                    .padding(.bottom, 6)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.system(size: 18, weight: .medium, design: .serif))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(description)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 240)
        .padding(20)
        .accessibilityElement(children: .contain)
    }
}
