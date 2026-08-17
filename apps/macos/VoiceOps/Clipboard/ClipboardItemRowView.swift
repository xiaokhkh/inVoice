import SwiftUI

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

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leadingView
            VStack(alignment: .leading, spacing: 4) {
                Text(previewText)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(metaText)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onPin) {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .opacity(item.pinned || hovering || isSelected ? 1.0 : 0.35)

                if hovering || isSelected {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)

                    Button(action: onInject) {
                        Image(systemName: "arrow.turn.down.left")
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onTapGesture(count: 2) {
            onInject()
        }
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                onHoverImage(item.type == .image ? item : nil)
            } else {
                onHoverImage(nil)
            }
        }
    }

    private var previewText: String {
        if item.type == .image {
            if let path = item.contentOriginalPath {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Image"
        }
        let text = item.contentText ?? ""
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private var leadingView: some View {
        Group {
            if item.type == .image, let image = loadThumbnail() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: item.source == .voiceops ? "waveform" : "doc.text")
                    .foregroundColor(item.source == .voiceops ? .accentColor : .secondary)
                    .frame(width: 18)
            }
        }
    }

    private func loadThumbnail() -> NSImage? {
        guard let path = item.contentImagePath else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
