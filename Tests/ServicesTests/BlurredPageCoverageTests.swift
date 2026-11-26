import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import CoreGraphics
import CoreImage
import CoreText
import Extract
import Foundation
import Retrieval
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing
@testable import Services

@Suite struct BlurredPageCoverageTests {
    /// All five PDF pages contain only pixels. The original rule on page 3 is blurred before the image enters the PDF.
    private func gardenScan(at url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 640, height: 820)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        for page in 1...5 {
            let bitmap = try #require(CGContext(data: nil, width: 640, height: 820, bitsPerComponent: 8, bytesPerRow: 2560,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(bounds)
            bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
            let lines = page == 3 ? ["Moonflower seedlings must grow in amber pots."] :
                ["Greenhouse handbook, section \(page).", "Water the trays each morning.", "Count the trays before closing the garden."]
            for (i, line) in lines.enumerated() {
                bitmap.textPosition = CGPoint(x: 30, y: 700 - 50 * i)
                let value = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                CTLineDraw(CTLineCreateWithAttributedString(value), bitmap)
            }
            var image = try #require(bitmap.makeImage())
            if page == 3 {
                let blurred = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: 48)
                image = try #require(CIContext().createCGImage(blurred, from: bounds))
            }
            pdf.beginPDFPage(nil); pdf.draw(image, in: bounds); pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    @Test func filingAndSearchIdentifyTheUnreadableRulePage() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-garden-\(UUID())")
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            var catalog = try #require(try JSONParser.parse(Data(contentsOf: url)).value.objectValue)
            catalog.set("documents", .array([]))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: support) }
        let commands = Commands(support: support, deviceID: "dev"), watcher = IntakeWatcher(support: support)
        try adoptAsCommand(folder, commands: commands, now: pNow, today: today)
        let helper = IntakeCommandTests()
        let setup = IntakeCommandTests.Setup(commands: commands, folder: folder, watcher: watcher)
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let scan = intake.appendingPathComponent("greenhouse.pdf")
        try gardenScan(at: scan)
        let rows = helper.rows(setup)
        _ = watcher.scan(binders: rows, commands: commands, now: pNow)
        let prepared = watcher.prepare(binders: rows, deviceID: "dev", reader: .inProcess)
        #expect(prepared.readings.values.first?.pageGrades == [.good, .good, .unreadable, .good, .good])
        #expect(watcher.scan(binders: rows, commands: commands, now: pNow, prepared: prepared, requireReading: true).carded == 1)
        let card = try #require(helper.open(setup).first { $0.raw["provenance"]?["intake"]?["name"] == .str("greenhouse.pdf") })
        #expect(try helper.approve(setup, card, folder: "garden")["ok"] == .bool(true))
        let path = try #require(Teka.read(folder).catalog?["documents"]?.arrayValue?.last?["path"]?.stringValue)
        let found = try ClaudeBinderContext.search(folder: folder, support: support, query: "moonflower", limit: 8,
                                                   reader: HelperDocumentReader(binder: folder, reader: .inProcess))
        #expect(found.sources.isEmpty && found.incomplete == 1)
        #expect(found.gaps.first?.path == path && found.gaps.first?.pages == [3])
        #expect(found.coverageLine == "1 document not fully read: \(path) (page 3).")
    }
}
