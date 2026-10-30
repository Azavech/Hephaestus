import SwiftUI

/// Draws the banners of the window at its bottom center (docs/ui/shell.md §8.3).
public struct BannerOverlay: View {
    @Environment(WindowBanners.self) private var windowBanners

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(windowBanners.banners) { banner in
                BannerRow(banner: banner) {
                    windowBanners.dismiss(banner.id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 560)
        .padding(16)
        .animation(.easeOut(duration: 0.2), value: windowBanners.banners)
    }
}

/// One banner: symbol, message and close button.
private struct BannerRow: View {
    let banner: Banner
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            symbol
            Text(banner.message)
                .font(.callout)
                .lineLimit(3)
            Spacer()
            Button(action: close) {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderStyle, lineWidth: 1)
        }
        .shadow(radius: 8, y: 2)
    }

    @ViewBuilder
    private var symbol: some View {
        switch banner.style {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
    }

    private var borderStyle: AnyShapeStyle {
        switch banner.style {
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.4))
        case .info:
            return AnyShapeStyle(.separator)
        }
    }
}
