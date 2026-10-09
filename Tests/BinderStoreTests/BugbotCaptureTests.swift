import BinderFormat
@testable import BinderStore
import CryptoKit
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

// Regression tests for the review of the capture and clerk modules (increment 1). Invented data only.

@Suite(.serialized) struct BugbotCaptureTests {
    // qcRtE: an op log left empty or torn by adoption is not adopted, and adoption can run again.
    @Test func qcRtE_anEmptyOrTornOpLogIsNotAdopted() throws {
        for contents in ["", #"{"id":"0199"#] {
            let folder = try makeTeka(fixture: "sprava-v0")
            try AtomicFile.makePrivateFolder(folder.appendingPathComponent(".sprava"))
            try Data(contents.utf8).write(to: folder.appendingPathComponent(".sprava/ops.ndjson"))
            #expect(!Teka.read(folder).isAdopted)
            try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: pNow)
            #expect(Teka.read(folder).isAdopted)
        }
    }
}
