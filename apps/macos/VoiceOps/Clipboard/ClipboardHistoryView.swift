import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    let onInject: (ClipboardItem) -> Void
    let onHoverImage: (ClipboardItem?) -> Void
    let onManage: () -> Void
    @FocusState private var searchFocused: Bool
    @AppStorage(ClipboardCapturePolicy.enabledKey) private var captureClipboard = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("剪贴板").font(.system(size: 16, weight: .semibold))
                    Text(captureClipboard ? "选中记录，回车粘贴到原应用" : "收集已暂停 · 已有记录仍可使用")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("管理记录", action: onManage).controlSize(.small)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文字或图片文件名…", text: Binding(get: { viewModel.query }, set: viewModel.setQuery))
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索剪贴板")
                if viewModel.isSearching { ProgressView().controlSize(.small) }
                if !viewModel.query.isEmpty {
                    Button { viewModel.clearQuery() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
            }
            .padding(10).background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            Picker("记录分类", selection: Binding(get: { viewModel.category }, set: viewModel.setCategory)) {
                ForEach(ClipboardHistoryViewModel.Category.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if viewModel.items.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                                Text(viewModel.query.isEmpty ? "这里还没有记录" : "没有找到匹配内容").font(.headline)
                                Text(viewModel.category == .all && viewModel.query.isEmpty
                                     ? (captureClipboard ? "复制文字或图片后，会自动出现在这里。" : "在管理页恢复收集，即可保存新复制的内容。")
                                     : "试试其他关键词或分类。")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !viewModel.query.isEmpty || viewModel.category != .all {
                                    Button("查看全部记录") { viewModel.resetFilters() }
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemRowView(
                                item: item, isSelected: index == viewModel.selectedIndex,
                                metaText: viewModel.metaText(for: item),
                                onSelect: { viewModel.selectIndex(index) }, onCopy: { Task { await viewModel.copyItem(item) } },
                                onPin: { viewModel.togglePinned(item) }, onInject: { onInject(item) },
                                onDelete: { viewModel.deleteItem(item) }, onHoverImage: onHoverImage
                            ).id(item.id)
                        }
                    }
                }
                .onChange(of: viewModel.selectedItem()?.id) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Text(viewModel.message ?? "\(viewModel.items.count) 条 · ↑↓ 选择 · ⌘C 复制 · ↩ 粘贴 · Esc 关闭")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.counts.undoable > 0 {
                    Button("撤销删除") { viewModel.undoDeletion() }.controlSize(.small).disabled(viewModel.isBusy || viewModel.isSearching)
                }
                Button("粘贴") {
                    if let item = viewModel.selectedItem() { onInject(item) }
                }.buttonStyle(.borderedProminent).controlSize(.small).disabled(viewModel.selectedItem() == nil || viewModel.isSearching || viewModel.isTransferring)
            }.frame(minHeight: 28)
        }
        .padding(18).frame(width: 600, height: 490)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if notification.object is ClipboardHistoryPanel { searchFocused = true }
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
