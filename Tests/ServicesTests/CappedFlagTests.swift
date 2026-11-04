import BinderStore
import Clerk
import Testing

@Suite struct CappedFlagTests {
    /// A card says "may have missed things" once by finding this flag: if the words drifted, it would stop saying so.
    @Test func theCardAndTheClerkMeanTheSameFlag() {
        #expect(Proposal.cappedFlag == Clerk.cappedFlag)
    }
}
