@testable import Clerk
import Foundation
import Testing

/// Increment 7: intake files are read before they are carded, email messages come with their attachments, and
/// the clerk's document reading replaces the code-built card (docs/adaptation-layer.md §4). All examples invented.
@Suite(.serialized) struct IntakeReadingTests {
    @Test func guardrailWordsAreSoftenedAndCodeCanClassifyAlone() {
        #expect(Clerk.softened("INVENTED HEIGHTS SYNDICATE of co-owners; syndicates") == "INVENTED HEIGHTS association of co-owners; associations")
        #expect(Clerk.codeClass(["payment", "deadline"]) == "action")
        #expect(Clerk.codeClass(["minutes", "governing"]) == "information")
        #expect(Clerk.codeClass(["governing"]) == "governing")
        #expect(Clerk.codeClass([]) == nil)
    }
}
