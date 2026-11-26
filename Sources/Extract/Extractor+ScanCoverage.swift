import CoreGraphics
import Vision

extension Extractor {
    /// Vision's confidence describes recognized words. Compare their bounds to the marks on the
    /// page as well, so an isolated sharp heading does not vouch for the rest of a damaged scan.
    static func hasUnrecognizedInk(_ image: CGImage, lines: [VNRecognizedText]) -> Bool {
        let scale = 384.0 / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return true }
        let pixels = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(bounds)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        // Count the area of a mark, independently of its darkness. Blur spreads a dark
        // stroke into a broad pale shape. Use the local paper brightness on tinted scans.
        var total = 0
        for y in stride(from: 0, to: height, by: 24) {
            let rows = y..<min(y + 24, height)
            for x in stride(from: 0, to: width, by: 24) {
                let columns = x..<min(x + 24, width)
                var paper: UInt8 = 0
                for row in rows {
                    for col in columns { paper = max(paper, pixels[row * width + col]) }
                }
                for row in rows {
                    for col in columns {
                        let index = row * width + col
                        let marked = Int(paper) - Int(pixels[index]) >= 8
                        pixels[index] = marked ? 0 : 255
                        if marked { total += 1 }
                    }
                }
            }
        }
        var words = 0
        for line in lines {
            for word in line.string.split(whereSeparator: { $0.isWhitespace }) {
                words += 1
                guard words <= 4_096 else { return true }
                guard let box = try? line.boundingBox(for: word.startIndex..<word.endIndex) else { continue }
                let rect = box.boundingBox.applying(CGAffineTransform(scaleX: bounds.width, y: bounds.height))
                ctx.fill(rect.insetBy(dx: -1, dy: -1))
            }
        }
        let remaining = pixels.count { $0 < 128 }
        return remaining >= 40 && remaining > total / 5
    }
}
