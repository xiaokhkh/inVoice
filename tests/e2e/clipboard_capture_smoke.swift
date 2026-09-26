import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct ClipboardCaptureSmoke {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-capture-test-\(UUID())")
        let store = ClipboardStore(directory: directory)
        let pb = NSPasteboard(name: .init("invoice-capture-test-\(UUID())"))
        let observer = ClipboardObserver(store: store, pasteboard: pb, captureEnabled: { true })
        defer {
            observer.stop()
            store.waitForPendingWrites()
            pb.clearContents(); pb.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "ClipboardCaptureTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<300 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(false, "capture did not settle")
        }
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = context.makeImage()!
        func encode(_ type: UTType) -> Data {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let png = encode(.png), jpeg = encode(.jpeg)
        try check(ClipboardImageProcessor.pngData(from: .data(png)) == png, "PNG bytes and transparency must be preserved")
        let converted = ClipboardImageProcessor.pngData(from: .data(jpeg))!
        let source = CGImageSourceCreateWithData(converted as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try check(CGImageSourceGetType(source) as String? == UTType.png.identifier && decoded.width == 64 && decoded.height == 32,
                  "non-PNG images preserve dimensions and produce PNG")
        try check(ClipboardImageProcessor.pngData(from: .data(Data([1, 2, 3]))) == nil, "invalid images are rejected")
        let original = directory.appendingPathComponent("original.png")
        try png.write(to: original)
        try check(ClipboardImageProcessor.pngData(from: .file(original)) == png, "file capture preserves PNG bytes")

        observer.start()
        pb.clearContents(); pb.setData(png, forType: .png)
        observer.poll()
        pb.clearContents(); pb.setString("latest copy while image prepares", forType: .string)
        observer.poll()
        try await waitFor { store.counts().total == 2 }
        try check(store.getRecentItems().first?.contentText == "latest copy while image prepares", "pending copy is captured after image in correct order")
        let storedImage = store.getRecentItems(filter: .init(type: .image)).first!
        try check(ClipboardImageProcessor.loadStoredPNG(path: storedImage.contentImagePath!) == png, "stored bytes round-trip")
        pb.clearContents(); pb.writeObjects([original as NSURL])
        observer.poll()
        try await waitFor { store.getRecentItems(filter: .init(type: .image)).first?.contentOriginalPath == original.path }
        try check(store.counts().total == 2, "copying the same PNG file deduplicates and retains its source path")
        let richText = NSAttributedString(string: "RTF-only content")
        let rtf = richText.rtf(from: NSRange(location: 0, length: richText.length), documentAttributes: [:])!
        pb.clearContents(); pb.setData(rtf, forType: .rtf)
        observer.poll()
        try await waitFor { store.getRecentItems().first?.contentText == "RTF-only content" }

        // Stop cancels an already captured snapshot before it can commit.
        pb.clearContents(); pb.setString("cancel this capture", forType: .string)
        observer.poll(); observer.stop()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(store.counts().total == 3, "stopping cancels in-flight capture")
        observer.start()
        pb.clearContents(); pb.setString("private", forType: .string)
        pb.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        observer.poll()
        try await Task.sleep(nanoseconds: 40_000_000)
        try check(store.counts().total == 3, "sensitive types are still excluded")
        print("PASS: PNG byte preservation, JPEG conversion, file capture/deduplication, RTF, background ordering, latest copy, cancellation, sensitive-type exclusion")
    }
}
