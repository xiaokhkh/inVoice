// Test processes do not capture the system clipboard or access the user's history store.
final class ClipboardObserver {
    static let shared = ClipboardObserver()
    func markInternalWrite(duration: Double = 0.6) {}
}
