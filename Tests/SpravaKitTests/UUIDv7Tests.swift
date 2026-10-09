import Foundation
@testable import SpravaKit
import Testing

@Suite struct UUIDv7Tests {
    @Test func idsIncreaseWithinOneMillisecond() {
        let at = Date(timeIntervalSince1970: 1_791_360_000)
        let ids = (0..<5000).map { _ in UUIDv7.make(now: at) }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.count == 36 && $0[$0.index($0.startIndex, offsetBy: 14)] == "7" })
    }
}
