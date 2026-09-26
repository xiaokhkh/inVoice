import SwiftUI
import ImageIO

extension ClipboardItem {
    var displayTitle: String {
        if type == .image {
            return contentOriginalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "剪贴板图片"
        }
        return String((contentText ?? "").prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var symbol: String { type == .image ? "photo" : (source == .voiceops ? "waveform" : "text.alignleft") }
}

/// Downsampling and disk reads are serialized off the main actor; small rows never decode full images.
actor ClipboardImageLoader {
    static let shared = ClipboardImageLoader()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func image(path: String, pixels: Int) -> NSImage? {
        let key = "\(pixels):\(path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: .zero)
        cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

struct ClipboardImageView: View {
    let item: ClipboardItem
    var pixels = 96
    @State private var image: NSImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if finished {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    .help("图片不可用，原文件可能已被移除")
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(image == nil && finished ? "图片文件不可用" : "图片预览")
        .task(id: "\(item.id):\(pixels)") {
            image = nil
            finished = false
            if let path = item.contentImagePath {
                let loaded = await ClipboardImageLoader.shared.image(path: path, pixels: pixels)
                guard !Task.isCancelled else { return }
                image = loaded
            }
            finished = true
        }
    }
}

struct ClipboardItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let metaText: String
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onInject: () -> Void
    let onDelete: () -> Void
    let onHoverImage: (ClipboardItem?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if item.type == .image {
                ClipboardImageView(item: item).frame(width: 36, height: 36)
            } else {
                Image(systemName: item.symbol).foregroundStyle(.indigo).frame(width: 36)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle).lineLimit(2).font(.system(size: 13))
                Text(metaText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onPin) { Image(systemName: item.pinned ? "pin.fill" : "pin") }
                .buttonStyle(.plain).foregroundStyle(item.pinned ? .indigo : .secondary)
                .help(item.pinned ? "取消固定" : "固定，保留常用内容")
                .accessibilityLabel(item.pinned ? "取消固定" : "固定")
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("复制")
                .accessibilityLabel("复制这条记录")
        }
        .padding(10)
        .background(isSelected ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onInject)
        .onTapGesture(perform: onSelect)
        .onHover { onHoverImage($0 && item.type == .image ? item : nil) }
        .contextMenu {
            Button("复制", action: onCopy)
            Button("粘贴到原应用", action: onInject)
            Button(item.pinned ? "取消固定" : "固定", action: onPin)
            Divider()
            Button("删除记录", role: .destructive, action: onDelete)
        }
    }
}
