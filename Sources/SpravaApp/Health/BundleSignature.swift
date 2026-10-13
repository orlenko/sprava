import Foundation
import Security

/// Whether the app bundle's own signature is whole. `SMAppService` loads the runtime's plist from the bundle's
/// sealed resources, so a bundle whose resources are not sealed (a build that stopped before the bundle was signed)
/// or were changed after signing cannot register its agents; macOS reports that only as a raw code (-67056).
enum BundleSignature {
    static let problemText = "Sprava's code signature is incomplete or damaged, so macOS will not load its background work. "
        + "Reinstall Sprava. A build from source must finish scripts/build-app.sh without errors."

    /// Nil when the bundle at `url` verifies strictly, resources included; otherwise the text to show.
    static func problem(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return problemText }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        return status == errSecSuccess ? nil : problemText + " (code \(status))"
    }

    /// The message for an error from `SMAppService.register()`: a signature refusal is named in plain words.
    static func registerFailure(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("codesign") || raw.localizedCaseInsensitiveContains("code signature") {
            return problemText + " (\(raw))"
        }
        return "Could not turn on background work: \(raw)"
    }
}
