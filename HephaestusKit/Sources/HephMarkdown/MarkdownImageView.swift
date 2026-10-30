import HephCore
import ImageIO
import SwiftUI

/// An image of a paragraph: loading, loaded or failed. Inside an active link it is tappable.
struct MarkdownImageView: View {
    let image: MarkdownImageReference
    let context: MarkdownRenderContext

    var body: some View {
        Group {
            if let linkIndex = image.linkIndex, context.links.indices.contains(linkIndex) {
                Button {
                    context.open(context.links[linkIndex])
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .task(id: image.target) {
            guard let target = image.target else { return }
            await context.imageStore.load(target, with: context.loadImage)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let target = image.target {
            switch context.imageStore.state(of: target) {
            case .loaded(let cgImage)?:
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: CGFloat(cgImage.width))
                    .accessibilityLabel(image.alt)
            case .failed?:
                failure
            case .loading?, nil:
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 160, height: 100)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        } else {
            failure
        }
    }

    /// The `photo` symbol and the alt text (or the source when the alt text is empty).
    private var failure: some View {
        HStack {
            Image(systemName: "photo")
            Text(image.alt.isEmpty ? image.source : image.alt)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
        )
    }
}

enum MarkdownImageState {
    case loading
    case loaded(CGImage)
    case failed
}

/// The images of a `MarkdownView`, by target. It is state of the view, so it survives source changes.
@MainActor @Observable
final class MarkdownImageStore {
    private var states: [MarkdownLinkTarget: MarkdownImageState] = [:]

    func state(of target: MarkdownLinkTarget) -> MarkdownImageState? {
        states[target]
    }

    /// Loads a target that is not in the store yet with `loader`, then decodes its first frame off the main actor.
    func load(_ target: MarkdownLinkTarget, with loader: MarkdownImageLoader) async {
        guard states[target] == nil else { return }
        states[target] = .loading
        do {
            let data = try await loader(target)
            let image = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
            if let image {
                states[target] = .loaded(image)
            } else {
                Log.markdown.debug("Image data not readable")
                states[target] = .failed
            }
        } catch {
            if Task.isCancelled {
                // The view went away: a later appearance loads it again.
                states[target] = nil
            } else {
                Log.markdown.debug("Image load failed: \(error.localizedDescription)")
                states[target] = .failed
            }
        }
    }

    /// The first frame, decoded by ImageIO; nil for data it cannot read.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// The image loader when the `MarkdownView` has none: `http` and `https` URLs with `URLSession.shared`, a status
    /// outside 200–299 failing; any other target fails.
    static func loadWithURLSession(_ target: MarkdownLinkTarget) async throws -> Data {
        guard case .external(let url) = target, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { throw MarkdownImageError.unsupportedTarget }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw MarkdownImageError.status(response.statusCode)
        }
        return data
    }
}

enum MarkdownImageError: Error {
    case unsupportedTarget
    case status(Int)
}
