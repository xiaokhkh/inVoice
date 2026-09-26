import Foundation

// Generated content only. Exercises the shipping store with a history beyond the old cap.
@main struct ClipboardCapacityBenchmark {
    static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-capacity-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        let payload = String(repeating: "中文 synthetic content ", count: 100)
        for index in 0..<5_000 {
            store.recordSystemText("entry \(index)\n" + payload, appBundleID: nil)
        }
        let counts = store.counts()
        precondition(counts.total == 5_000 && counts.ordinaryBytes < counts.capacityBytes)
        print("fixture=5000-text-clips estimated-bytes=\(counts.ordinaryBytes)")
        measure("first page + counts") {
            precondition(store.getRecentItems(limit: 101).count == 101)
            _ = store.counts()
        }
        measure("deep page at offset 4000") {
            precondition(store.getRecentItems(limit: 101, offset: 4_000).count == 101)
        }
        measure("search oldest clip outside first page") {
            precondition(store.getRecentItems(limit: 101, query: "entry 0\n").count == 1)
        }
        measure("common search first page") {
            precondition(store.getRecentItems(limit: 101, query: "synthetic").count == 101)
        }
        var index = 5_000
        measure("capture including worker and capacity enforcement") {
            store.recordSystemText("entry \(index)\n" + payload, appBundleID: nil)
            store.waitForPendingWrites()
            index += 1
        }
    }

    static func measure(_ title: String, operation: () -> Void) {
        var samples: [Double] = []
        for _ in 0..<30 {
            autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                operation()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
        }
        samples.sort()
        print(String(format: "%@: median=%.3f ms p95=%.3f ms n=%d", title,
                     samples[samples.count / 2], samples[Int(Double(samples.count) * 0.95)], samples.count))
    }
}
