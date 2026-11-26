import AppKit
import CoreImage
import Testing
@testable import Extract

@Suite struct PartialScanTests {
    @Test func aDamagedHalfOfEachLineIsChecked() throws {
        let lines = ["Maple leaves cover the distant garden path", "Shallow trays shelter the young seedlings",
                     "Clouds gather above the old copper lantern", "Three painted gates open toward the meadow",
                     "The seed packet describes a rare moonflower", "Plant the cuttings after the morning frost",
                     "Each clay pot stands beside a smooth stone", "Write the harvest date beneath the drawing"]
        let source = CIImage(cgImage: Fixtures.textImage(lines, width: 1190, height: 680))
        let right = CGRect(x: 440, y: 0, width: 750, height: 680)
        let original = Set(lines.joined(separator: " ").lowercased().split(separator: " ").map(String.init))
        var partial = 0
        for sigma in [6.0, 10.0, 15.0] {
            let softened = source.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: right)
            let pixels = try #require(CIContext().createCGImage(softened.composited(over: source), from: source.extent))
            let result = Extractor.extract(Fixtures.png(pixels), name: "invented-garden.png")
            let page = try #require(result.pageReadings.first)
            let found = Set(page.text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            let correct = original.intersection(found).count
            if correct * 4 < original.count * 3 {
                partial += 1
                #expect(page.grade != .good)
            }
        }
        #expect(partial >= 2)
    }
}
