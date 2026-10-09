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
                guard let image = render(page) else { return held(i, "has no text layer and cannot be drawn for OCR (too large, or empty)") }
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

    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5   // about 180 dpi, enough for OCR
        // Checked before converting to Int: a page box from untrusted bytes may be huge, or not a number at all.
        let fw = box.width * scale, fh = box.height * scale
        guard fw >= 1, fh >= 1, fw * fh < 60_000_000 else { return nil }
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
