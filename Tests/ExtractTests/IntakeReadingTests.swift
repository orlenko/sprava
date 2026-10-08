@testable import Extract
import Foundation
import Testing

/// Increment 7: intake files are read before they are carded, email messages come with their attachments, and
/// the clerk's document reading replaces the code-built card (docs/adaptation-layer.md §4). All examples invented.
@Suite(.serialized) struct IntakeReadingTests {
    @Test func headerDatesAreReadInTheSendersOffset() {
        #expect(IntakeReading.day(ofHeader: "Thu, 01 Oct 2026 23:30:00 -0400")?.description == "2026-10-01")
        #expect(IntakeReading.day(ofHeader: "1 Oct 2026 09:00:00 +0200 (CEST)")?.description == "2026-10-01")
        #expect(IntakeReading.day(ofHeader: "2026-10-01T09:00:00Z")?.description == "2026-10-01")
        #expect(IntakeReading.day(ofHeader: "2026-10-01")?.description == "2026-10-01")
        #expect(IntakeReading.day(ofHeader: "next week") == nil)
    }
}
