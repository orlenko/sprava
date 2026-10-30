import SpravaKit
import Testing

/// The build string About, the heartbeat and Health share, read from the Info.plist build-app.sh stamps.
@Suite struct BuildIdentityTests {
    @Test func aStampedBundleNamesItsVersionCountAndCommit() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412", "SpravaCommit": "119b640"]
        #expect(BuildIdentity.describe(info) == "0.1.0 (412 · 119b640)")
        #expect(BuildIdentity.aboutVersion(info) == "412 · 119b640")
    }

    @Test func aBundleBuiltOutsideACheckoutKeepsItsPlistVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
        #expect(BuildIdentity.describe(info) == "0.1.0 (1)")
    }

    @Test func noBundleIsDev() {
        #expect(BuildIdentity.describe(nil) == "dev")
        #expect(BuildIdentity.describe([:]) == "dev")
        #expect(BuildIdentity.aboutVersion(nil) == nil)
    }
}
