import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct DashboardTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func adopted() throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        return folder
    }

    @Test func theDoctorAsksForTheAddendum() throws {
        let folder = try adopted()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-doctor-\(UUID().uuidString)")
        let device = try #require(Owner.device(of: folder))
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        try Data("# Manual\nRun lifeproj publish after each digest.\n".utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        var findings = Doctor.run(rows: rows, deviceID: device, registry: nil, support: support, spool: support)
        #expect(findings.contains { $0.level == .fix && $0.text.contains("addendum") })
        try Data(("# Manual\n" + ManualAddendum.text).utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        findings = Doctor.run(rows: [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))],
                              deviceID: device, registry: nil, support: support, spool: support)
        #expect(!findings.contains { $0.text.contains("addendum") })
    }
}
