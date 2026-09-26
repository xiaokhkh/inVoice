import AppKit
import CryptoKit
import Foundation
import SQLite3

final class ClipboardStore {
    static let shared = ClipboardStore()
    static let didChangeNotification = Notification.Name("VoiceOpsClipboardStoreDidChange")

    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    struct Filter {
        var type: ClipboardItem.ItemType?
        var source: ClipboardItem.Source?
        var pinnedOnly = false
    }

    private let queue = DispatchQueue(label: "voiceops.clipboard.store")
    static let defaultCapacityBytes: Int64 = 1_073_741_824
    private let capacityBytes: Int64
    private var captureWarning: String?
    private let dbURL: URL
    private let imagesURL: URL
    private var db: OpaquePointer?

    init(directory: URL? = nil, capacityBytes: Int64 = ClipboardStore.defaultCapacityBytes) {
        self.capacityBytes = max(1, capacityBytes)
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = directory ?? support.appendingPathComponent("mlx-voiceops", isDirectory: true)
        imagesURL = base.appendingPathComponent("clipboard_images", isDirectory: true)
        dbURL = base.appendingPathComponent("clipboard.sqlite3")

        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)

        openDatabase()
        createTables()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func recordSystemText(_ text: String, appBundleID: String?) {
        guard !text.isEmpty else { return }
        queue.async {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let bytes = Self.storageCost(text: text, selectedText: nil)
            let hash = self.hashText(text)
            if self.refreshDuplicate(type: .text, source: .system, text: text, hash: hash, storageBytes: bytes,
                                     appBundleID: appBundleID) { return }
            guard self.acceptsSize(bytes) else { return }
            let item = ClipboardItem(
                id: UUID(),
                type: .text,
                source: .system,
                sessionID: nil,
                timestamp: self.nextTimestamp(),
                contentText: text,
                contentImagePath: nil,
                contentOriginalPath: nil,
                contentHash: hash,
                pinned: false,
                selectedText: nil,
                voiceIntent: nil,
                llmUsed: nil,
                appBundleID: appBundleID
            )
            if self.insert(item, storageBytes: bytes) {
                self.captureWarning = nil
                self.enforceRetention()
                self.notifyChange()
            }
        }
    }

    func recordVoiceOpsText(
        sessionID: UUID,
        text: String,
        selectedText: String?,
        voiceIntent: String?,
        llmUsed: String?,
        appBundleID: String?
    ) {
        guard !text.isEmpty else { return }
        queue.async {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let bytes = Self.storageCost(text: text, selectedText: selectedText)
            let hash = self.hashText(text)
            if self.refreshDuplicate(type: .text, source: .voiceops, text: text, hash: hash, storageBytes: bytes,
                                     appBundleID: appBundleID, sessionID: sessionID,
                                     selectedText: selectedText, voiceIntent: voiceIntent, llmUsed: llmUsed) { return }
            guard self.acceptsSize(bytes) else { return }
            let item = ClipboardItem(
                id: UUID(),
                type: .text,
                source: .voiceops,
                sessionID: sessionID,
                timestamp: self.nextTimestamp(),
                contentText: text,
                contentImagePath: nil,
                contentOriginalPath: nil,
                contentHash: hash,
                pinned: false,
                selectedText: selectedText,
                voiceIntent: voiceIntent,
                llmUsed: llmUsed,
                appBundleID: appBundleID
            )
            if self.insert(item, storageBytes: bytes) {
                self.captureWarning = nil
                self.enforceRetention()
                self.notifyChange()
            }
        }
    }

    func recordSystemImage(_ imageData: Data, appBundleID: String?, originalPath: String? = nil) {
        guard !imageData.isEmpty else { return }
        queue.async {
            let bytes = Self.storageCost(imageBytes: Int64(imageData.count))
            let hash = self.hashData(imageData)
            if self.refreshDuplicate(type: .image, source: .system, text: nil, hash: hash, storageBytes: bytes,
                                     appBundleID: appBundleID, originalPath: originalPath) { return }
            guard self.acceptsSize(bytes) else { return }
            let id = UUID()
            let path = self.imageURL(for: id).path
            do {
                try imageData.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return
            }
            let item = ClipboardItem(
                id: id,
                type: .image,
                source: .system,
                sessionID: nil,
                timestamp: self.nextTimestamp(),
                contentText: nil,
                contentImagePath: path,
                contentOriginalPath: originalPath,
                contentHash: hash,
                pinned: false,
                selectedText: nil,
                voiceIntent: nil,
                llmUsed: nil,
                appBundleID: appBundleID
            )
            if self.insert(item, storageBytes: bytes) {
                self.captureWarning = nil
                self.enforceRetention()
                self.notifyChange()
            } else {
                self.removeImage(atPath: path)
            }
        }
    }

    /// Search and category filters cover the whole history before page boundaries are applied.
    func getRecentItems(limit: Int = Int(Int32.max), filter: Filter? = nil, query: String = "", offset: Int = 0) -> [ClipboardItem] {
        queue.sync {
            var clauses = ["deleted_at IS NULL"]
            var args: [String] = []
            if let type = filter?.type {
                clauses.append("type = ?")
                args.append(type.rawValue)
            }
            if let source = filter?.source {
                clauses.append("source = ?")
                args.append(source.rawValue)
            }
            if filter?.pinnedOnly == true { clauses.append("pinned = 1") }
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                // instr treats %, _ and backslashes literally, unlike LIKE.
                clauses.append("(instr(lower(COALESCE(content_text, '')), lower(?)) > 0 OR instr(lower(COALESCE(content_original_path, '')), lower(?)) > 0)")
                args.append(contentsOf: [search, search])
            }
            let sql = """
            SELECT id, type, source, session_id, timestamp, content_text, content_image_path,
                   content_original_path, content_hash, pinned, selected_text, voice_intent, llm_used,
                   app_bundle_id, last_used_at
            FROM clipboard_items
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY pinned DESC, timestamp DESC, rowid DESC
            LIMIT ? OFFSET ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            for (index, arg) in args.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), arg, -1, sqliteTransient)
            }
            sqlite3_bind_int(statement, Int32(args.count + 1), Int32(clamping: max(0, limit)))
            sqlite3_bind_int64(statement, Int32(args.count + 2), Int64(max(0, offset)))
            return fetchItems(from: statement)
        }
    }

    struct Counts {
        var total = 0
        var pinned = 0
        var undoable = 0
        var ordinaryBytes: Int64 = 0
        var pinnedBytes: Int64 = 0
        var undoBytes: Int64 = 0
        var capacityBytes: Int64 = ClipboardStore.defaultCapacityBytes
        var warning: String?
    }

    func counts() -> Counts {
        queue.sync {
            let sql = "SELECT SUM(deleted_at IS NULL), SUM(deleted_at IS NULL AND pinned = 1), SUM(deleted_at IS NOT NULL), SUM(CASE WHEN deleted_at IS NULL AND pinned = 0 THEN storage_bytes ELSE 0 END), SUM(CASE WHEN deleted_at IS NULL AND pinned = 1 THEN storage_bytes ELSE 0 END), SUM(CASE WHEN deleted_at IS NOT NULL THEN storage_bytes ELSE 0 END) FROM clipboard_items;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return Counts() }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return Counts() }
            return Counts(total: Int(sqlite3_column_int64(statement, 0)),
                          pinned: Int(sqlite3_column_int64(statement, 1)),
                          undoable: Int(sqlite3_column_int64(statement, 2)),
                          ordinaryBytes: sqlite3_column_int64(statement, 3),
                          pinnedBytes: sqlite3_column_int64(statement, 4),
                          undoBytes: sqlite3_column_int64(statement, 5),
                          capacityBytes: capacityBytes, warning: captureWarning)
        }
    }

    func getItemsBySession(_ sessionID: UUID) -> [ClipboardItem] {
        queue.sync {
            let sql = """
            SELECT id, type, source, session_id, timestamp, content_text, content_image_path,
                   content_original_path, content_hash, pinned, selected_text, voice_intent, llm_used,
                   app_bundle_id, last_used_at
            FROM clipboard_items
            WHERE session_id = ? AND deleted_at IS NULL
            ORDER BY pinned DESC, timestamp DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, sqliteTransient)
            return fetchItems(from: statement)
        }
    }

    /// nil clears only unpinned clips. The last deletion batch survives relaunch and can be undone.
    /// Purge the previous batch only after the new deletion commits; never remove original user files.
    func deleteItems(ids: [UUID]? = nil) -> Int? {
        queue.sync {
            guard let db else { return nil }
            if let ids, ids.isEmpty { return 0 }
            let selection = ids.map { "id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? "pinned = 0"
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return nil }
            var committed = false
            defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
            var previousPaths: [String] = []
            var old: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT content_image_path FROM clipboard_items WHERE deleted_at IS NOT NULL;", -1, &old, nil) == SQLITE_OK else { return nil }
            while sqlite3_step(old) == SQLITE_ROW {
                if let path = readString(old, index: 0) { previousPaths.append(path) }
            }
            sqlite3_finalize(old)
            guard sqlite3_exec(db, "DELETE FROM clipboard_items WHERE deleted_at IS NOT NULL;", nil, nil, nil) == SQLITE_OK else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE clipboard_items SET deleted_at = ? WHERE deleted_at IS NULL AND \(selection);", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Self.nowMs())
            for (index, id) in (ids ?? []).enumerated() {
                sqlite3_bind_text(statement, Int32(index + 2), id.uuidString, -1, sqliteTransient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
            let changed = Int(sqlite3_changes(db))
            guard changed > 0 else { return 0 } // rollback also preserves the previous undo batch
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { return nil }
            committed = true
            previousPaths.forEach { removeImage(atPath: $0) }
            notifyChange()
            return changed
        }
    }

    func undoDeletion() -> Int? {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE clipboard_items SET deleted_at = NULL, timestamp = ?1, last_used_at = ?1 WHERE deleted_at IS NOT NULL;", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, nextTimestamp())
            guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
            let count = Int(sqlite3_changes(db))
            enforceRetention()
            notifyChange()
            return count
        }
    }

    func imageURL(for id: UUID) -> URL {
        imagesURL.appendingPathComponent("\(id.uuidString).png")
    }

    func setPinned(_ pinned: Bool, for id: UUID) {
        queue.async { [self] in
            // An oversized migrated/pinned clip must not delete itself when unpinned.
            if !pinned {
                var size: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT storage_bytes FROM clipboard_items WHERE id = ? AND pinned = 1 AND deleted_at IS NULL;", -1, &size, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(size, 1, id.uuidString, -1, sqliteTransient)
                let oversized = sqlite3_step(size) == SQLITE_ROW && sqlite3_column_int64(size, 0) > capacityBytes
                sqlite3_finalize(size)
                if oversized {
                    captureWarning = "这条内容超过普通历史空间，已继续固定。可手动删除。"
                    notifyChange()
                    return
                }
            }
            let sql = "UPDATE clipboard_items SET pinned = ?1, timestamp = CASE WHEN ?2 = 0 THEN ?3 ELSE timestamp END, last_used_at = CASE WHEN ?2 = 0 THEN ?3 ELSE last_used_at END WHERE id = ?4 AND deleted_at IS NULL;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
            sqlite3_bind_int(statement, 2, pinned ? 1 : 0)
            sqlite3_bind_int64(statement, 3, nextTimestamp())
            sqlite3_bind_text(statement, 4, id.uuidString, -1, sqliteTransient)
            if sqlite3_step(statement) == SQLITE_DONE {
                self.enforceRetention()
                self.notifyChange()
            }
        }
    }

    /// Successful copy/paste extends retention without making the visible history jump.
    /// Previews and failed operations never count as use.
    func markUsed(_ id: UUID) {
        queue.async { [self] in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE clipboard_items SET last_used_at = ? WHERE id = ? AND deleted_at IS NULL;", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, nextTimestamp())
            sqlite3_bind_text(statement, 2, id.uuidString, -1, sqliteTransient)
            sqlite3_step(statement)
        }
    }

    /// Used by background capture to bound the number of outstanding image buffers.
    func waitForPendingWrites() { queue.sync {} }

    private func openDatabase() {
        guard db == nil else { return }
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createTables() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            source TEXT NOT NULL,
            session_id TEXT,
            timestamp INTEGER NOT NULL,
            content_text TEXT,
            content_image_path TEXT,
            content_original_path TEXT,
            content_hash TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            selected_text TEXT,
            voice_intent TEXT,
            llm_used TEXT,
            app_bundle_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_clipboard_timestamp ON clipboard_items(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_clipboard_hash ON clipboard_items(content_hash);
        """
        for stmt in sql.split(separator: "\n\n") {
            sqlite3_exec(db, String(stmt), nil, nil, nil)
        }
        sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN content_original_path TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN deleted_at INTEGER;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN last_used_at INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        // Existing clips start with their capture date; upgrades do not evict or reorder history.
        sqlite3_exec(db, "UPDATE clipboard_items SET last_used_at = timestamp WHERE last_used_at = 0;", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_clipboard_usage ON clipboard_items(last_used_at);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_clipboard_recent_active ON clipboard_items(pinned DESC, timestamp DESC) WHERE deleted_at IS NULL;", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_clipboard_identity_active ON clipboard_items(type, source, content_hash) WHERE deleted_at IS NULL;", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_clipboard_lru_active ON clipboard_items(last_used_at, timestamp) WHERE pinned = 0 AND deleted_at IS NULL;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE clipboard_items ADD COLUMN storage_bytes INTEGER NOT NULL DEFAULT -1;", nil, nil, nil)
        migrateStorageCosts()
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_clipboard_page ON clipboard_items(deleted_at, pinned DESC, timestamp DESC);", nil, nil, nil)
        // Keep capacity/count queries off the potentially large text payload pages.
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_clipboard_storage ON clipboard_items(deleted_at, pinned, storage_bytes);", nil, nil, nil)
    }

    private func insert(_ item: ClipboardItem, storageBytes: Int64) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT INTO clipboard_items (
            id, type, source, session_id, timestamp, content_text, content_image_path,
            content_original_path, content_hash, pinned, selected_text, voice_intent, llm_used,
            app_bundle_id, last_used_at, storage_bytes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, item.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, item.type.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, item.source.rawValue, -1, sqliteTransient)
        if let sessionID = item.sessionID?.uuidString {
            sqlite3_bind_text(statement, 4, sessionID, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int64(statement, 5, item.timestamp)
        bindOptional(statement, index: 6, value: item.contentText)
        bindOptional(statement, index: 7, value: item.contentImagePath)
        bindOptional(statement, index: 8, value: item.contentOriginalPath)
        sqlite3_bind_text(statement, 9, item.contentHash, -1, sqliteTransient)
        sqlite3_bind_int(statement, 10, item.pinned ? 1 : 0)
        bindOptional(statement, index: 11, value: item.selectedText)
        bindOptional(statement, index: 12, value: item.voiceIntent)
        bindOptional(statement, index: 13, value: item.llmUsed)
        bindOptional(statement, index: 14, value: item.appBundleID)
        sqlite3_bind_int64(statement, 15, item.timestamp)
        sqlite3_bind_int64(statement, 16, storageBytes)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func bindOptional(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func fetchItems(from statement: OpaquePointer?) -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = readString(statement, index: 0)
            let type = readString(statement, index: 1)
            let source = readString(statement, index: 2)
            let sessionID = readString(statement, index: 3)
            let timestamp = sqlite3_column_int64(statement, 4)
            let contentText = readString(statement, index: 5)
            let contentImagePath = readString(statement, index: 6)
            let contentOriginalPath = readString(statement, index: 7)
            let contentHash = readString(statement, index: 8) ?? ""
            let pinned = sqlite3_column_int(statement, 9) == 1
            let selectedText = readString(statement, index: 10)
            let voiceIntent = readString(statement, index: 11)
            let llmUsed = readString(statement, index: 12)
            let appBundleID = readString(statement, index: 13)

            guard let idString = id, let uuid = UUID(uuidString: idString) else { continue }
            guard let typeValue = type.flatMap(ClipboardItem.ItemType.init(rawValue:)) else { continue }
            guard let sourceValue = source.flatMap(ClipboardItem.Source.init(rawValue:)) else { continue }
            let sessionUUID = sessionID.flatMap(UUID.init(uuidString:))

            items.append(
                ClipboardItem(
                    id: uuid,
                    type: typeValue,
                    source: sourceValue,
                    sessionID: sessionUUID,
                    timestamp: timestamp,
                    contentText: contentText,
                    contentImagePath: contentImagePath,
                    contentOriginalPath: contentOriginalPath,
                    contentHash: contentHash,
                    pinned: pinned,
                    selectedText: selectedText,
                    voiceIntent: voiceIntent,
                    llmUsed: llmUsed,
                    appBundleID: appBundleID,
                    lastUsedAt: sqlite3_column_int64(statement, 14)
                )
            )
        }
        return items
    }

    private func readString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cstr = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cstr)
    }

    private func refreshDuplicate(
        type: ClipboardItem.ItemType, source: ClipboardItem.Source, text: String?, hash: String, storageBytes: Int64,
        appBundleID: String?, sessionID: UUID? = nil, selectedText: String? = nil,
        voiceIntent: String? = nil, llmUsed: String? = nil, originalPath: String? = nil
    ) -> Bool {
        let match = type == .text ? "content_hash = ? AND content_text = ?" : "content_hash = ?"
        let sql = """
        UPDATE clipboard_items SET timestamp = ?1, last_used_at = ?1, app_bundle_id = ?2,
            session_id = ?, selected_text = ?, voice_intent = ?, llm_used = ?,
            content_original_path = COALESCE(?, content_original_path), storage_bytes = ?
        WHERE id = (SELECT id FROM clipboard_items WHERE deleted_at IS NULL
            AND (pinned = 1 OR CAST(? AS INTEGER) <= CAST(? AS INTEGER)) AND type = ? AND source = ? AND \(match) ORDER BY timestamp DESC LIMIT 1);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, nextTimestamp())
        var values: [String?] = [appBundleID, sessionID?.uuidString, selectedText, voiceIntent, llmUsed,
                                 originalPath, String(storageBytes), String(storageBytes), String(capacityBytes), type.rawValue, source.rawValue, hash]
        if type == .text { values.append(text) }
        for (index, value) in values.enumerated() {
            bindOptional(statement, index: Int32(index + 2), value: value)
        }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) > 0 else { return false }
        captureWarning = nil
        enforceRetention()
        notifyChange()
        return true
    }

    // Capacity applies to ordinary content. Pinned records and the last undo batch are protected.
    private func enforceRetention() {
        guard let db else { return }
        var total: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(storage_bytes), 0), MIN(storage_bytes) FROM clipboard_items WHERE pinned = 0 AND deleted_at IS NULL;", -1, &total, nil) == SQLITE_OK else { return }
        let result = sqlite3_step(total)
        var excess = sqlite3_column_int64(total, 0) - capacityBytes
        let costsKnown = sqlite3_column_int64(total, 1) >= 0
        sqlite3_finalize(total)
        guard result == SQLITE_ROW, costsKnown, excess > 0 else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            captureWarning = "历史空间清理未完成，已有记录已保留。"
            return
        }
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                captureWarning = "历史空间清理未完成，已有记录已保留。"
            }
        }
        var oldest: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, content_image_path, storage_bytes FROM clipboard_items WHERE pinned = 0 AND deleted_at IS NULL ORDER BY last_used_at, timestamp, rowid;", -1, &oldest, nil) == SQLITE_OK else { return }
        var victims: [(String, String?)] = []
        while excess > 0, sqlite3_step(oldest) == SQLITE_ROW {
            guard let id = readString(oldest, index: 0) else { continue }
            victims.append((id, readString(oldest, index: 1)))
            excess -= sqlite3_column_int64(oldest, 2)
        }
        sqlite3_finalize(oldest)
        guard excess <= 0 else { return }
        var deletion: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM clipboard_items WHERE id = ?;", -1, &deletion, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(deletion) }
        for (id, _) in victims {
            sqlite3_reset(deletion)
            sqlite3_bind_text(deletion, 1, id, -1, sqliteTransient)
            guard sqlite3_step(deletion) == SQLITE_DONE else { return }
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { return }
        committed = true
        for (_, path) in victims { if let path { removeImage(atPath: path) } }
    }

    private static func storageCost(text: String? = nil, selectedText: String? = nil, imageBytes: Int64 = 0) -> Int64 {
        // Payload bytes plus a small per-record allowance for IDs and other metadata.
        256 + Int64(text?.utf8.count ?? 0) + Int64(selectedText?.utf8.count ?? 0) + imageBytes
    }

    private func acceptsSize(_ bytes: Int64) -> Bool {
        guard bytes <= capacityBytes else {
            captureWarning = "这次内容超过历史空间预算，未保存；当前剪贴板不受影响。"
            notifyChange()
            return false
        }
        return true
    }

    private func migrateStorageCosts() {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, length(CAST(COALESCE(content_text, '') AS BLOB)) + length(CAST(COALESCE(selected_text, '') AS BLOB)), content_image_path FROM clipboard_items WHERE storage_bytes < 0;", -1, &statement, nil) == SQLITE_OK else { return }
        var costs: [(String, Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = readString(statement, index: 0) else { continue }
            let imageBytes = readString(statement, index: 2).flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0)[.size]) as? NSNumber
            }?.int64Value ?? 0
            costs.append((id, 256 + sqlite3_column_int64(statement, 1) + imageBytes))
        }
        sqlite3_finalize(statement)
        guard !costs.isEmpty else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE clipboard_items SET storage_bytes = ? WHERE id = ?;", -1, &update, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(update) }
        for (id, bytes) in costs {
            sqlite3_reset(update)
            sqlite3_bind_int64(update, 1, bytes)
            sqlite3_bind_text(update, 2, id, -1, sqliteTransient)
            guard sqlite3_step(update) == SQLITE_DONE else { return }
        }
        committed = sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private func hashText(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hashData(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func removeImage(atPath path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == imagesURL.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A strict order also covers several copies in the same millisecond and restoring a batch.
    private func nextTimestamp() -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(COALESCE((SELECT MAX(timestamp) FROM clipboard_items), 0), COALESCE((SELECT MAX(last_used_at) FROM clipboard_items), 0));", -1, &statement, nil) == SQLITE_OK else { return Self.nowMs() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return Self.nowMs() }
        return max(Self.nowMs(), sqlite3_column_int64(statement, 0) + 1)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

extension ClipboardStore: @unchecked Sendable {}
