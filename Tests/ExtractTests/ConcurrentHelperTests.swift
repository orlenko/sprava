import Foundation
import Testing
@testable import Extract

@Suite struct ConcurrentHelperTests {
    @Test func simultaneousReadersEachReceiveTheirWholeInput() async throws {
        let helper = try BugbotHelperAndHTMLTests().stub("cat")
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let body = String(repeating: "invented seed list ", count: 8_192)
        let count = min(24, max(4, ProcessInfo.processInfo.activeProcessorCount + 2))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 1...count {
                group.addTask {
                    let text = "Page \(number) " + body
                    let bytes = try JSONSerialization.data(withJSONObject: ["kind": "text", "text": text])
                    let result = try ExtractHelper.launch(helper, data: bytes, name: "garden.txt", timeout: 10)
                    #expect(result.text == text)
                }
            }
            try await group.waitForAll()
        }
    }
}
