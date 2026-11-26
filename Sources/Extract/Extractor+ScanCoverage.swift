import CoreGraphics
import Vision

extension Extractor {
    /// Vision's confidence describes recognized words. Compare their bounds to the marks on the
    /// page as well, so an isolated sharp heading does not vouch for the rest of a damaged scan.
    static func hasUnrecognizedInk(_ image: CGImage, lines: [VNRecognizedText]) -> Bool {
        // Examine local evidence at the source resolution. Downsampling a pale glyph into its
        // background, or dividing its ink by all the dark words on the page, can erase it.
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 8_000_000 / height else { return true }
        let gray = CGColorSpaceCreateDeviceGray()
        func bitmap() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        guard let original = bitmap(), let mask = bitmap(), let source = original.data, let marked = mask.data else { return true }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        original.setFillColor(gray: 1, alpha: 1)
        original.fill(bounds)
        original.draw(image, in: bounds)
        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(bounds)
        mask.setFillColor(gray: 1, alpha: 1)
        let scale = CGAffineTransform(scaleX: bounds.width, y: bounds.height)
        var words = 0
        for line in lines {
            for word in line.string.split(whereSeparator: { $0.isWhitespace }) {
                words += 1
                guard words <= 4_096, let box = try? line.boundingBox(for: word.startIndex..<word.endIndex) else { return true }
                let rect = box.boundingBox.applying(scale)
                mask.fill(rect.insetBy(dx: -2, dy: -2))
            }
        }
        let pixels = source.assumingMemoryBound(to: UInt8.self)
        let covered = marked.assumingMemoryBound(to: UInt8.self)
        // A residual patch of visible texture in *any* neighborhood prevents a good grade.
        // The criterion is local and independent of how much recognized text surrounds it.
        for y in stride(from: 0, to: height, by: 16) {
            let rows = y..<min(y + 16, height)
            for x in stride(from: 0, to: width, by: 16) {
                let columns = x..<min(x + 16, width)
                var light: UInt8 = 0
                for row in rows {
                    for col in columns { light = max(light, pixels[row * width + col]) }
                }
                var unexplained = 0
                for row in rows {
                    for col in columns {
                        let index = row * width + col
                        if covered[index] == 0 && Int(light) - Int(pixels[index]) >= 2 {
                            unexplained += 1
                            if unexplained >= 8 { return true }
                        }
                    }
                }
            }
        }
        return false
    }
}
