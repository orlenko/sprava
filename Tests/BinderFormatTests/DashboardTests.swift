@testable import BinderFormat
import Foundation
import Testing

@Suite(.serialized) struct DashboardTests {
    @Test func escapingAndCodeSpans() {
        #expect(Dashboard.escape("![x](https://tracker.example/p.png)") == "\\!\\[x\\]\\(https://tracker.example/p.png\\)")
        #expect(Dashboard.escape("a\tb\nc\u{202E}d\u{07}") == "a b cd")
        #expect(Dashboard.escape("<b>#1|2</b>") == "\\<b\\>\\#1\\|2\\</b\\>")
        #expect(Dashboard.codeSpan("id-1") == "`id-1`")
        #expect(Dashboard.codeSpan("a`b") == "``a`b``")
        #expect(Dashboard.codeSpan("`x") == "`` `x ``")
    }
}
