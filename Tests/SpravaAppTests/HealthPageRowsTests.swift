import Foundation
import Services
@testable import SpravaApp
import Testing

/// The Health page's rows: each section's ids are its own, so a macOS List never shows a doctor finding under
/// Backup, and doctor findings read as sentences. Invented names and temporary support folders only.
@Suite struct HealthPageRowsTests {
    @Test func rowsInDifferentSectionsNeverShareAnID() {
        let backup = HealthLine.rows("backup", ["Invented binder", "Another invented binder"])
        let doctor = HealthLine.rows("doctor", ["an invented finding", "another invented finding", "a third"])
        let refusals = HealthLine.rows("refusal", ["invented refusal"])
        let ids = backup.map(\.id) + doctor.map(\.id) + refusals.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(doctor.map(\.value) == ["an invented finding", "another invented finding", "a third"])
        // Within a section the id is the row's place, never its words.
        #expect(HealthLine.rows("doctor", ["other", "words", "here"]).map(\.id) == doctor.map(\.id))
    }

    @Test func doctorFindingsReadAsSentences() throws {
        #expect(Doctor.Finding.sentence(binder: nil, text: "a card has waited") == "A card has waited")
        #expect(Doctor.Finding.sentence(binder: "Invented binder", text: "the manual lacks it") == "Invented binder: The manual lacks it")
        #expect(Doctor.Finding.sentence(binder: nil, text: "") == "")
        // The unconfigured hub folder is said in plain words, at the level it had.
        let findings = Doctor.run(rows: [], deviceID: nil, registry: nil, support: try temporaryFolder())
        let spool = try #require(findings.first)
        #expect(spool.level == .note && spool.binder == nil)
        #expect(spool.sentence == "The shared hub folder is not set up on this Mac, so Sprava cannot check what each binder shares there")
    }
}
