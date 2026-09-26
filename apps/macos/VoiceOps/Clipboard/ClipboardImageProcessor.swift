import AppKit
import ImageIO
import UniformTypeIdentifiers

/// These functions run on background workers, never against a live pasteboard.
enum ClipboardImageProcessor {
    enum Input: Sendable {
        case data(Data)
        case file(URL)
    }

    static func pngData(from input: Input) -> Data? {
        let data: Data
        switch input {
        case .data(let value): data = value
        case .file(let url):
            // Copying a non-image file should not read its entire contents into memory.
            guard CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
            guard let value = try? Data(contentsOf: url) else { return nil }
            data = value
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            // Screenshots and most clipboard images are already PNG. Keep their encoded bytes:
            // decoding and re-encoding a 4K image wastes hundreds of milliseconds and a full bitmap.
            if CGImageSourceGetType(source) as String? == UTType.png.identifier,
               CGImageSourceGetStatus(source) == .statusComplete,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0,
               (properties[kCGImagePropertyPixelHeight] as? Int ?? 0) > 0 {
                return data
            }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return encode(image) }
        }
        // Preserve AppKit-only image representations without touching AppKit views or the pasteboard.
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return encode(cgImage)
    }

    static func loadStoredPNG(path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return data
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
