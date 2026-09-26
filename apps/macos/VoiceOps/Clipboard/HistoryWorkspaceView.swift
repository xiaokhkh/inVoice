import AppKit
import SwiftUI

struct HistoryWorkspaceView: View {
    @StateObject private var model: ClipboardHistoryViewModel

    init(store: ClipboardStore = .shared) {
        _model = StateObject(wrappedValue: ClipboardHistoryViewModel(store: store))
    }
    @AppStorage(ClipboardCapturePolicy.enabledKey) private var captureClipboard = true
    @AppStorage("clipboardWorkspaceCategory") private var savedCategory = "all"
    @State private var showClearConfirmation = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut("f")
                    .accessibilityLabel("聚焦搜索")
                TextField("搜索文字或图片文件名…", text: Binding(get: { model.query }, set: model.setQuery))
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索历史记录")
                if model.isSearching { ProgressView().controlSize(.small) }
                if !model.query.isEmpty {
                    Button { model.clearQuery() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
                Text("⌘F").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(11).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
            HStack {
                Picker("记录分类", selection: Binding(get: { model.category }, set: {
                    model.setCategory($0); savedCategory = $0.rawValue
                })) {
                    ForEach(ClipboardHistoryViewModel.Category.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 385)
                Spacer(minLength: 8)
                Menu {
                    Button(captureClipboard ? "暂停收集" : "恢复收集") { captureClipboard.toggle() }
                    Divider()
                    Button("清理未固定记录…", role: .destructive) { showClearConfirmation = true }
                        .disabled(model.counts.total == model.counts.pinned || model.isBusy)
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if !captureClipboard {
                HStack {
                    Label("已暂停收集", systemImage: "pause.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复") { captureClipboard = true }.buttonStyle(.link)
                }.font(.system(size: 11))
            }
            Group {
                if model.items.isEmpty { emptyState }
                else {
                    HStack(spacing: 0) {
                        historyList.frame(minWidth: 220, idealWidth: 255, maxWidth: 300)
                        Divider()
                        if let item = model.selectedItem() { detail(item).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            footer
        }
        .padding(24)
        .onAppear { model.setCategory(.init(rawValue: savedCategory) ?? .all) }
        .onChange(of: model.category) { savedCategory = $0.rawValue }
        .alert("清理所有未固定记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清理 \(model.counts.total - model.counts.pinned) 条", role: .destructive) { model.clearUnpinned() }
        } message: {
            Text("将清理所有分类中的未固定记录，保留 \(model.counts.pinned) 条固定内容。可在下次删除前撤销本次清理。")
        }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { model.selectedItem()?.id }, set: model.selectID)) {
                ForEach(model.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if item.type == .image { ClipboardImageView(item: item) }
                            else { Image(systemName: item.symbol).foregroundStyle(Color.accentColor) }
                        }.frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.displayTitle).lineLimit(2).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 4) {
                                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(Color.accentColor) }
                                Text(model.metaText(for: item)).lineLimit(1)
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 7).tag(item.id).id(item.id)
                    .contextMenu {
                        Button("复制") { model.copyItem(item) }
                        Button(item.pinned ? "取消固定" : "固定") { model.togglePinned(item) }
                        if item.type == .image { Button("在访达中显示") { model.revealImage(item) } }
                        Divider()
                        Button("删除记录", role: .destructive) { model.deleteItem(item) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { model.deleteSelected() }
            .onChange(of: model.selectedItem()?.id) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func detail(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(item.type == .image ? "图片预览" : "完整内容", systemImage: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.togglePinned(item) } label: { Image(systemName: item.pinned ? "pin.fill" : "pin") }
                    .buttonStyle(.plain).foregroundStyle(item.pinned ? Color.accentColor : Color.secondary)
                    .help(item.pinned ? "取消固定" : "固定记录，清理时保留")
                    .accessibilityLabel(item.pinned ? "取消固定" : "固定记录")
            }.padding(16)
            Divider().opacity(0.5)
            ScrollView {
                if let text = item.contentText {
                    Text(text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                } else {
                    ClipboardImageView(item: item, pixels: 1200)
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 360).padding(18)
                    Text(item.displayTitle).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    Button("在访达中显示") { model.revealImage(item) }.controlSize(.small).padding(.bottom, 16)
                }
            }.id(item.id).frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.sourceName(for: item)).font(.system(size: 10, weight: .medium))
                    Text(Date(timeIntervalSince1970: Double(item.timestamp) / 1_000), format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let text = item.contentText { Text("\(text.count) 字符").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                HStack {
                    Button(role: .destructive) { model.deleteItem(item) } label: { Image(systemName: "trash") }
                        .help("删除记录，可撤销").accessibilityLabel("删除当前记录").disabled(model.isBusy || model.isSearching)
                    Spacer()
                    Button { model.copyItem(item) } label: {
                        Label(model.copiedID == item.id ? "已复制" : "复制内容", systemImage: model.copiedID == item.id ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(model.isSearching)
                    .buttonStyle(.borderedProminent).keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("复制完整内容 · ⇧⌘C")
                }
            }.padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.query.isEmpty ? (model.category == .pinned ? "pin" : "doc.on.clipboard") : "magnifyingglass")
                .font(.system(size: 32, weight: .light)).foregroundStyle(.indigo.opacity(0.65))
            Text(emptyTitle).font(.system(size: 16, weight: .semibold))
            Text(emptyDescription).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.query.isEmpty || model.category != .all {
                Button("查看全部记录") { model.resetFilters() }
            } else if !captureClipboard {
                Button("恢复收集") { captureClipboard = true }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "没有找到匹配内容" }
        if model.category == .pinned { return "把常用内容固定在这里" }
        if model.category != .all { return "还没有\(model.category.title)记录" }
        return captureClipboard ? "下一次复制，从这里留下" : "剪贴板收集已暂停"
    }

    private var emptyDescription: String {
        if !model.query.isEmpty { return "试试更短的关键词，或清除筛选查看全部。" }
        if model.category == .pinned { return "点击记录上的图钉，常用内容会置顶保留。" }
        if model.category == .voice { return "完成一次语音输入后，结果会自动出现在这里。" }
        return captureClipboard ? "在任意应用复制文字或图片，即可在这里找回。" : "恢复后会保存新复制的内容，语音输入记录不受影响。"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(model.message ?? "\(model.items.count) 条记录 · 已固定 \(model.counts.pinned) 条")
                    .font(.system(size: 11)).foregroundStyle(model.message == nil ? Color.secondary : Color.accentColor)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if model.counts.undoable > 0 {
                    Button("撤销删除（\(model.counts.undoable) 条）") { model.undoDeletion() }
                        .controlSize(.small).disabled(model.isBusy || model.isSearching).help("可撤销上一次删除或清理，直到下一次删除")
                }
            }.frame(minHeight: 24)
            Label("仅保存在本机", systemImage: "lock")
                .help("保留最近 200 条记录，固定内容额外保留。可在右上角暂停收集。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
