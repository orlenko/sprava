import AppKit
@testable import SpravaApp
import Testing

/// #689: the rename alert has no default answer about the old name; Cancel sends nothing.
@Suite struct UseFolderNameChoiceTests {
    @Test func eachAnswerSaysWhoseTheOldNameIs() {
        #expect(BinderActions.formerNameChoice(.alertFirstButtonReturn) == "renamed")
        #expect(BinderActions.formerNameChoice(.alertSecondButtonReturn) == "copy")
        #expect(BinderActions.formerNameChoice(.alertThirdButtonReturn) == nil)
        #expect(BinderActions.formerNameChoice(.cancel) == nil)
        #expect(BinderActions.formerNameChoice(.abort) == nil)
    }
}
