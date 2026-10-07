import Foundation
import Testing
@testable import SpravaCore

@Suite struct CanonicalTests {
    func hash(_ text: String) throws -> String { try Canonical.hash(try JSONParser.parse(text).value) }

    /// teka-v0 §11 check 63.
    @Test func specVectors() throws {
        #expect(try hash(#"{"title": "Café"}"#) == "sha256:97abf59ac9ce42d34f62d32f6b75eb18a16cedc16ef9de9c818e902a93c51e5f")
        #expect(try hash("{\"title\": \"Café\"}") == "sha256:97abf59ac9ce42d34f62d32f6b75eb18a16cedc16ef9de9c818e902a93c51e5f")
        #expect(try hash("{\"title\": \"Cafe\u{0301}\"}") == "sha256:e7156f5c49620b91d15fd0591e9502fe9790b7f1159314a6f77591083fbd7fac")
        let numbers = try JSONParser.parse(#"{"amount": 12.5, "big": 1e16, "small": 1e-7}"#).value
        #expect(try Canonical.serialize(numbers) == #"{"amount":12.5,"big":10000000000000000,"small":1e-7}"#)
        #expect(try Canonical.hash(numbers) == "sha256:bf32401fef70ae0645acbb210250c2874daa04e3fbc33c94e4ac6463c89d5acf")
        let keys = try JSONParser.parse("{\"ﬁ\": 1, \"😀\": 2}").value
        #expect(try Canonical.serialize(keys) == "{\"😀\":2,\"ﬁ\":1}")
        #expect(try Canonical.hash(keys) == "sha256:14dc6c14e11d686bbd1332452e5c8dc999ac1479def9c87e945308b1b27d469b")
    }

    /// RFC 8785 appendix B number samples (ECMAScript Number.prototype.toString).
    @Test(arguments: [
        (0.0, "0"), (-0.0, "0"), (1.0, "1"), (-1.0, "-1"), (12.5, "12.5"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
        (1e-6, "0.000001"), (1e-7, "1e-7"), (123456789012345680000.0, "123456789012345680000"),
        (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (0.1, "0.1"),
        (333333333.3333333, "333333333.3333333"), (4.50, "4.5"), (2e-3, "0.002"), (0.000001, "0.000001"),
        (9007199254740991.0, "9007199254740991"), (295147905179352830000.0, "295147905179352830000"),
    ])
    func ecmaNumbers(value: Double, expected: String) {
        #expect(Canonical.ecmaString(value) == expected)
    }

    @Test func prettyWriterKeepsOrderAndUnescapes() throws {
        let value = try JSONParser.parse(#"{"b":"З","a":[1,{"x":2.50}],"e":{},"f":[]}"#).value
        #expect(JSONWriter.pretty(value) == """
        {
          "b": "З",
          "a": [
            1,
            {
              "x": 2.50
            }
          ],
          "e": {},
          "f": []
        }

        """)
        #expect(JSONWriter.compact(value) == #"{"b":"З","a":[1,{"x":2.50}],"e":{},"f":[]}"#)
        // Round trip keeps the value.
        #expect(try JSONParser.parse(JSONWriter.pretty(value)).value == value)
    }

    @Test func sampleImportSnapshotHashesToItsRecordedHash() throws {
        let url = try #require(Bundle.module.url(forResource: "ops", withExtension: "ndjson", subdirectory: "Fixtures/ops"))
        let first = try #require(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first)
        let op = try JSONParser.parse(String(first)).value
        let catalog = try #require(op["args"]?["catalog"])
        #expect(try Canonical.hash(catalog) == op["before_hash"]?.stringValue)
    }
}
