import Foundation
import SpravaKit

/// Where development runs keep their state: the installed app's support folder with `-dev` added, which
/// `sprava-runtime --dev` and the `sprava dev` commands share. Its own device id, records and client registry, so
/// a development run never shares a read-modify-write with the installed runtime, and binders the installed app
/// owns are read-only to it.
public enum DevelopmentSupport {
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let production = SpravaPaths.supportDirectory(environment: environment)
        return production.deletingLastPathComponent().appendingPathComponent(production.lastPathComponent + "-dev", isDirectory: true)
    }
}
