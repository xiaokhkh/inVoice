import AppKit

@main
struct ClipboardDeliverySmoke {
    @MainActor static func main() async throws {
        let pb = NSPasteboard(name: .init("inVoice.image-delivery-tests.\(UUID())"))
        defer { pb.clearContents(); pb.releaseGlobally() }
        let data = Data([137, 80, 78, 71])
        var posts = 0
        var permission = false
        var pid: pid_t? = 100
        let injector = FocusInjector(
            clipboard: PasteboardTransaction(pasteboard: pb),
            accessibilityGranted: { permission }, frontmostPID: { pid },
            pasteEventPoster: { _ in posts += 1; return true }
        )
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ClipboardDeliveryTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let denied = await injector.deliverImage(data, targetPID: 100)
        try check(denied.status == .copiedNoPermission && posts == 0 && pb.data(forType: .png) == data, "permission fallback")
        permission = true
        let wrongTarget = await injector.deliverImage(data, targetPID: 200)
        try check(wrongTarget.status == .copiedFocusChanged && posts == 0, "destination guard")
        let inserted = await injector.deliverImage(data, targetPID: 100)
        try check(inserted.status == .inserted && posts == 1, "single paste")
        let focusChange = Task { @MainActor in
            try await Task.sleep(nanoseconds: 10_000_000)
            pid = 200
        }
        let changed = await injector.deliverImage(data, targetPID: 100)
        try await focusChange.value
        try check(changed.status == .copiedFocusChanged && posts == 1, "focus changed while settling")
        pid = 100
        let newCopy = Task { @MainActor in
            try await Task.sleep(nanoseconds: 10_000_000)
            pb.clearContents()
            pb.setString("newer clipboard", forType: .string)
        }
        let superseded = await injector.deliverImage(data, targetPID: 100)
        try await newCopy.value
        try check(superseded.status == .copiedSessionSuperseded && posts == 1 && pb.string(forType: .string) == "newer clipboard", "never paste unrelated newer content")
        print("PASS: 5 image delivery scenarios; isolated pasteboard, no keyboard events posted")
    }
}
