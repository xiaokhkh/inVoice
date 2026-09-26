import Foundation

struct ClipboardItem: Identifiable, Hashable {
    enum ItemType: String {
        case text
        case image
    }

    enum Source: String {
        case voiceops
        case system
    }

    let id: UUID
    let type: ItemType
    let source: Source
    let sessionID: UUID?
    let timestamp: Int64
    let contentText: String?
    let contentImagePath: String?
    let contentOriginalPath: String?
    let contentHash: String
    let pinned: Bool
    let selectedText: String?
    let voiceIntent: String?
    let llmUsed: String?
    let appBundleID: String?
    var lastUsedAt: Int64 = 0
}
