import BinderFormat
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit

/// Fixed-layout RGBX bitmap. Only the signed reader decodes a PDF or compressed image.
public struct PagePreview: Sendable {
    public static let maxSide = 1536
    public let width: Int
    public let height: Int
    public let pixels: Data

    public init?(width: Int, height: Int, pixels: Data) {
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height),
              pixels.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Two unsigned big-endian 16-bit dimensions, followed by exactly four bytes per pixel.
    public var wire: Data {
        Data([UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)]) + pixels
    }

    init?(wire: Data) {
        guard wire.count >= 4 else { return nil }
        let header = Array(wire.prefix(4))
        self.init(width: Int(header[0]) * 256 + Int(header[1]), height: Int(header[2]) * 256 + Int(header[3]),
                  pixels: Data(wire.dropFirst(4)))
    }

    package static func render(_ data: Data, name: String, number: Int) -> Self? {
        let limits = Extractor.Limits()
        guard !DocumentPaths.isKeyFile(name), data.count <= limits.bytes, (1...limits.pages).contains(number) else { return nil }
        switch Extractor.sniff(data, name: name) {
        case .pdf:
            guard let document = PDFDocument(data: data), !document.isLocked, (number...limits.pages).contains(document.pageCount),
                  let page = document.page(at: number - 1), let ref = page.pageRef,
                  !Extractor.drawsImagePast(limits.pixels, ref) else { return nil }
            let box = ref.getBoxRect(.mediaBox)
            let sideways = ref.rotationAngle % 180 != 0
            let width = sideways ? box.height : box.width
            let height = sideways ? box.width : box.height
            return bitmap(width: width, height: height) { context, bounds in
                context.scaleBy(x: bounds.width / width, y: bounds.height / height)
                page.displaysAnnotations = true
                page.draw(with: .mediaBox, to: context)
            }
        case .png, .jpeg, .heic, .tiff:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  (number...limits.pages).contains(CGImageSourceGetCount(source)),
                  let pixels = Extractor.declaredPixels(source, number - 1), pixels > 0, pixels <= Double(limits.pixels),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, number - 1, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary) else { return nil }
            return bitmap(width: CGFloat(image.width), height: CGFloat(image.height)) { $0.draw(image, in: $1) }
        default: return nil
        }
    }

    private static func bitmap(width: CGFloat, height: CGFloat, draw: (CGContext, CGRect) -> Void) -> Self? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let scale = CGFloat(maxSide) / max(width, height)
        let w = max(1, min(maxSide, Int(width * scale))), h = max(1, min(maxSide, Int(height * scale)))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        draw(context, rect)
        return Self(width: w, height: h, pixels: Data(bytes: bytes, count: w * h * 4))
    }
}

extension ExtractHelper {
    public static func pagePreview(file: URL, under root: URL, number: Int, expectedDigest: String) throws -> PagePreview {
        try pagePreview(file: file, under: root, number: number, reader: .located(), expectedDigest: expectedDigest)
    }

    static func pagePreview(file: URL, under root: URL, number: Int, reader: Reader, expectedDigest: String) throws -> PagePreview {
        let limit = Extractor.Limits()
        guard !DocumentPaths.isKeyFile(file.lastPathComponent), (1...limit.pages).contains(number),
              case .ok(let data) = read(file, under: root, limit: limit.bytes) else { throw Failure(message: "the page cannot be opened") }
        if SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != expectedDigest {
            throw Failure(message: "this document changed since the page was checked")
        }
        let preview: PagePreview?
        switch reader {
        case .inProcess: preview = PagePreview.render(data, name: file.lastPathComponent, number: number)
        case .missing: throw missing
        case .helper(let url):
            guard isSandboxed(url) else { throw unsandboxed }
            let wire = try reply(url, data: data, arguments: [file.lastPathComponent, "--page-preview", String(number)],
                                 timeout: 30, maxAnswer: 4 + PagePreview.maxSide * PagePreview.maxSide * 4, grace: 2)
            preview = PagePreview(wire: wire)
        }
        guard let preview else { throw Failure(message: "the page could not be drawn") }
        return preview
    }
}
