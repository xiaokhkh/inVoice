import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Synthetic, deterministic 4K data only. No user clipboard, database, or model access.
@main struct ClipboardBenchmark {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        let width = 3840, height = 2160
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 926
        for pixel in 0..<(width * height) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            rgba[pixel * 4] = UInt8(truncatingIfNeeded: seed)
            rgba[pixel * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            rgba[pixel * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let png = encode(image)
        print("fixture=deterministic-noisy-4K bytes=\(png.count)")
        measure("PNG capture preparation", repeats: 7) {
            #if OPTIMIZED
            let prepared = ClipboardImageProcessor.pngData(from: .data(png))!
            #else
            let source = CGImageSourceCreateWithData(png as CFData, nil)!
            let prepared = encode(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
            #endif
            precondition(!prepared.isEmpty)
        }
        var callTimes: [Double] = []
        for _ in 0..<15 {
            let start = ProcessInfo.processInfo.systemUptime
            store.recordSystemImage(png, appBundleID: nil)
            callTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            _ = store.counts()
        }
        report("record image caller time", samples: callTimes)
        for i in 0..<200 {
            store.recordSystemText("clip \(i) " + String(repeating: "中英文 search fixture ", count: 300), appBundleID: nil)
        }
        _ = store.counts()
        measure("search 200 long text clips", repeats: 30) {
            _ = store.getRecentItems(query: "fixture")
            _ = store.counts()
        }
    }
    static func encode(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func measure(_ title: String, repeats: Int, operation: () -> Void) {
        var samples: [Double] = []
        for _ in 0..<repeats {
            autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                operation()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        report(title, samples: samples)
    }
    static func report(_ title: String, samples: [Double]) {
        let sorted = samples.sorted()
        print(String(format: "%@: median=%.3f ms p95=%.3f ms n=%d", title,
                     sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.count))
    }
}
