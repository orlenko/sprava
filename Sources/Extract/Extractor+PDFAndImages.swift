import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

extension Extractor {
    // MARK: - PDF: the text layer, OCR for pages without one, every page

    static func pdf(_ data: Data, limits: Limits) -> Result {
        guard let doc = PDFDocument(data: data) else { return Result(kind: "pdf", text: "", textFrom: "parsed", problem: "the PDF does not open") }
        if doc.isEncrypted && doc.isLocked { return Result(kind: "pdf", text: "", textFrom: "parsed", problem: "the PDF is protected by a password") }
        let count = doc.pageCount
        guard count <= limits.pages else { return Result(kind: "pdf", text: "", textFrom: "parsed", pages: count, problem: "more pages than the limit (\(count))") }
        var parts: [String] = []
        var layerPages = 0, ocrFound = false
        // A page that does not open, draw or go through OCR holds the whole file: the other pages alone are not the
        // document. A page whose OCR ran and found nothing is read, and empty.
        func held(_ i: Int, _ why: String) -> Result { Result(kind: "pdf", text: "", textFrom: "parsed", pages: count, problem: "page \(i + 1) \(why)") }
        for i in 0..<count {
            guard let page = doc.page(at: i) else { return held(i, "of the PDF does not open") }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if layer.count >= 20 {
                layerPages += 1
                parts.append(layer)
            } else {
                // An image the page draws is decoded whole, whatever the page's size: one declared past the pixel
                // limit holds the file before drawing.
                if let ref = page.pageRef, drawsImagePast(limits.pixels, ref) { return held(i, "holds a picture larger than the pixel limit") }
                guard let image = render(page, maxPixels: limits.pixels) else { return held(i, "has no text layer and cannot be drawn for OCR (too large, or empty)") }
                guard let text = ocr(image) else { return held(i, "could not be read by OCR") }
                if !text.isEmpty { ocrFound = true }
                parts.append(text)
            }
        }
        // One of the contract's values (adaptation-layer §3): any text that came from OCR makes the reading `ocr`, so
        // the card asks for its names and numbers to be checked; a blank page that OCR found empty changes nothing.
        let from = ocrFound || (layerPages == 0 && count > 0) ? "ocr" : "text-layer"
        return Result(kind: "pdf", text: parts.joined(separator: "\n\n"), textFrom: from, pages: count)
    }

    /// Whether a page draws an image declared past `limit` pixels: inline in its content, among its XObjects and
    /// patterns, in its annotations' appearances, and inside the forms and patterns those draw. The search has a
    /// budget of objects; one that runs out of it counts as too large, never as clean.
    static func drawsImagePast(_ limit: Int, _ page: CGPDFPage) -> Bool {
        guard let dict = page.dictionary else { return false }
        let content = CGPDFContentStreamCreateWithPage(page)
        if inlineImagePast(Double(limit), in: content) { return true }
        var visits = 0
        return imagePast(Double(limit), in: dict, parent: content, depth: 0, visits: &visits)
    }

    /// Whether a content stream holds an inline image (`BI` ... `ID` ... `EI`) declared past `limit` pixels.
    private static func inlineImagePast(_ limit: Double, in content: CGPDFContentStreamRef) -> Bool {
        let found = InlineImages(limit: limit)
        guard let table = CGPDFOperatorTableCreate() else { return true }
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            guard let info else { return }
            let found = Unmanaged<InlineImages>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFScannerPopStream(scanner, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) else { return }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            // An inline image may give its size abbreviated (W, H) or in full.
            guard CGPDFDictionaryGetInteger(d, "W", &w) || CGPDFDictionaryGetInteger(d, "Width", &w),
                  CGPDFDictionaryGetInteger(d, "H", &h) || CGPDFDictionaryGetInteger(d, "Height", &h) else { return }
            if Double(w) * Double(h) > found.limit { found.past = true }
        }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(found).toOpaque())
        withExtendedLifetime(found) { _ = CGPDFScannerScan(scanner) }
        return found.past
    }

    private static func imagePast(_ limit: Double, in dict: CGPDFDictionaryRef, parent: CGPDFContentStreamRef, depth: Int,
                                  visits: inout Int) -> Bool {
        var drawn: [CGPDFStreamRef] = []
        func streams(in container: CGPDFDictionaryRef) {
            CGPDFDictionaryApplyBlock(container, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream { drawn.append(stream) }
                return true
            }, nil)
        }
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources {
            for key in ["XObject", "Pattern"] {
                var container: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(resources, key, &container), let container { streams(in: container) }
            }
        }
        // Drawing a page draws its annotations' normal appearances too: a stream, or one per state.
        var annotations: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Annots", &annotations), let annotations {
            for i in 0..<min(CGPDFArrayGetCount(annotations), 10_000) {
                var annotation: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?, normal: CGPDFObjectRef?
                guard CGPDFArrayGetDictionary(annotations, i, &annotation), let annotation,
                      CGPDFDictionaryGetDictionary(annotation, "AP", &appearance), let appearance,
                      CGPDFDictionaryGetObject(appearance, "N", &normal), let normal else { continue }
                var stream: CGPDFStreamRef?, states: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(normal, .stream, &stream), let stream { drawn.append(stream) }
                else if CGPDFObjectGetValue(normal, .dictionary, &states), let states { streams(in: states) }
            }
        }
        for stream in drawn {
            visits += 1
            guard visits <= 10_000, depth < 16 else { return true }
            guard let d = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            let kind = CGPDFDictionaryGetName(d, "Subtype", &subtype) ? subtype.map { String(cString: $0) } : nil
            switch kind {
            case "Image":
                // The image, and the soft mask or mask image drawn with it, each decoded at its own size.
                var images: [CGPDFDictionaryRef] = [d]
                for key in ["SMask", "Mask"] {
                    var mask: CGPDFStreamRef?
                    if CGPDFDictionaryGetStream(d, key, &mask), let mask, let m = CGPDFStreamGetDictionary(mask) { images.append(m) }
                }
                for m in images {
                    var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                    guard CGPDFDictionaryGetInteger(m, "Width", &w), CGPDFDictionaryGetInteger(m, "Height", &h) else { continue }
                    if Double(w) * Double(h) > limit { return true }
                }
            default:
                // A form, a tiling pattern or an appearance: its own content, and whatever it draws, are looked
                // through the same way.
                var own: CGPDFDictionaryRef?
                let resources = CGPDFDictionaryGetDictionary(d, "Resources", &own) ? own ?? d : d
                let content = CGPDFContentStreamCreateWithStream(stream, resources, parent)
                if inlineImagePast(limit, in: content) { return true }
                if imagePast(limit, in: d, parent: content, depth: depth + 1, visits: &visits) { return true }
            }
        }
        return false
    }

    static func render(_ page: PDFPage, maxPixels: Int) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5   // about 180 dpi, enough for OCR
        // Checked before converting to Int: a page box from untrusted bytes may be huge, or not a number at all.
        let fw = box.width * scale, fh = box.height * scale
        guard fw >= 1, fh >= 1, fw * fh < CGFloat(maxPixels) else { return nil }
        let w = Int(fw), h = Int(fh)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: - Images: OCR on the device, every page of a multi-page TIFF

    static func image(_ data: Data, limits: Limits) -> Result {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            return Result(kind: "image", text: "", textFrom: "ocr", problem: "the image does not open")
        }
        let count = CGImageSourceGetCount(src)
        guard count <= limits.pages else { return Result(kind: "image", text: "", textFrom: "ocr", pages: count, problem: "more pages than the limit (\(count))") }
        var parts: [String] = []
        for i in 0..<count {
            // The size a page declares is checked before it is decoded: a small file can declare a huge picture.
            guard let pixels = declaredPixels(src, i), pixels <= Double(limits.pixels) else {
                return Result(kind: "image", text: "", textFrom: "ocr", pages: count,
                              problem: "page \(i + 1) of the image is larger than the pixel limit, or declares no size")
            }
            // A page that does not open holds the whole file: the other pages alone are not the document.
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                return Result(kind: "image", text: "", textFrom: "ocr", pages: count, problem: "page \(i + 1) of the image does not open")
            }
            guard let text = ocr(img) else {
                return Result(kind: "image", text: "", textFrom: "ocr", pages: count, problem: "page \(i + 1) of the image could not be read by OCR")
            }
            parts.append(text)
        }
        return Result(kind: "image", text: parts.joined(separator: "\n\n"), textFrom: "ocr", pages: count)
    }

    /// The pixels a picture's header declares, read without decoding it; nil when it declares no size.
    static func declaredPixels(_ src: CGImageSource, _ i: Int) -> Double? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return w * h
    }

    /// The text Vision finds in an image, empty when it finds none; nil when recognition itself failed.
    public static func ocr(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let observations = request.results ?? []
        // Reading order: top to bottom, then left to right.
        let lines = observations.sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

/// What a scan for inline images found; handed to the scanner's C callback as its info pointer.
private final class InlineImages {
    let limit: Double
    var past = false
    init(limit: Double) { self.limit = limit }
}
