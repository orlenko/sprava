import Services
import SpravaKit

extension HealthModel {
    /// What Health says when the runtime that answers is another build than this app: one left running from before an
    /// update. Nil when they match, or when this app runs outside a bundle and has no build to compare.
    var staleRuntimeBuild: String? {
        guard case .success(let beat) = heartbeat else { return nil }
        return Self.buildMismatch(runtime: beat.build, app: BuildIdentity.current)
    }

    static func buildMismatch(runtime: String, app: String) -> String? {
        guard app != "dev", runtime != app else { return nil }
        return "Background work is running build \(runtime), not this app's \(app). Restart it to run this build."
    }
}
