import SwiftUI

/// 基于 PaperRss 原生 App 图标（去除红色准星与文字、背景透明化）渲染的品牌图标视图。
public struct PaperBrandIcon: View {
    public var width: CGFloat
    public var opacity: Double?

    public init(
        width: CGFloat = 78,
        opacity: Double? = nil
    ) {
        self.width = width
        self.opacity = opacity
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        image
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .opacity(opacity ?? (colorScheme == .dark ? 0.82 : 0.88))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: Image {
        #if SWIFT_PACKAGE
        Image("PaperEmptyBrandIcon", bundle: .module)
        #else
        Image("PaperEmptyBrandIcon")
        #endif
    }
}
