import Darwin
import Foundation
import SpravaKit

/// Effective first-party subscription check in the SAME prepared private environment as the turn.
/// This API is called by the application; constructing a launch never reads a personal credential home.
package enum ClaudeReadAccount {
    package enum Refused: Error { case firstPartySubscriptionRequired, unavailable }
    package static func verify(_ prepared: ClaudeReadLaunch.Prepared) async throws {
        try await Task.detached(priority: .userInitiated) {
            try check(prepared.launch)
        }.value
    }
    static func check(_ source: ClaudeReadOnlyTurn.Launch) throws {
        // Keep the exact sandbox/profile/native executable; auth status is a local metadata command,
        // not a model turn. Its email/organisation fields are neither returned nor logged.
        guard source.arguments.count >= 3 else { throw Refused.unavailable }
        let launch = ClaudeReadOnlyTurn.Launch(executable: source.executable,
            arguments: Array(source.arguments.prefix(3)) + ["--safe-mode", "--restricted", "--setting-sources", "",
                "--settings", "{\"disableAllHooks\":true}", "auth", "status"],
            environment: source.environment, directory: source.directory, sessionID: source.sessionID)
        let child = try ClaudeTurnProcess(launch, resume: false, sessionArgument: false)
        defer { _ = child.finish() }
        if child.input >= 0 { close(child.input); child.input = -1 }
        let started = ContinuousClock.now
        var output = Data(), count = 0, buffer = [UInt8](repeating: 0, count: 8192)
        var outputOpen = true, errorOpen = true
        while outputOpen || errorOpen {
            guard started.duration(to: .now) < .seconds(15) else {
                guard child.finish() else { throw ClaudeReadOnlyTurn.Failure.exitUnconfirmed }
                throw Refused.unavailable
            }
            var polls = [pollfd(fd: outputOpen ? child.output : -1, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: errorOpen ? child.error : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&polls, 2, 50) < 0, errno != EINTR { throw Refused.unavailable }
            for i in 0..<2 where polls[i].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let read = buffer.withUnsafeMutableBytes { Darwin.read(polls[i].fd, $0.baseAddress, $0.count) }
                if read > 0 {
                    count += read
                    guard count <= 64 * 1024 else { throw Refused.unavailable }
                    if i == 0 { output.append(contentsOf: buffer.prefix(read)) }
                } else if read == 0 { if i == 0 { outputOpen = false } else { errorOpen = false } }
                else if errno != EAGAIN && errno != EINTR { throw Refused.unavailable }
            }
        }
        guard child.finish() else { throw ClaudeReadOnlyTurn.Failure.exitUnconfirmed }
        guard child.successfulExit else { throw Refused.firstPartySubscriptionRequired }
        try validate(output, expectedConfig: source.directory.appendingPathComponent("config").path)
    }
    static func validate(_ data: Data, expectedConfig: String) throws {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8),
              let parsed = try? JSONParser.parse(text), parsed.safety.isSafe,
              parsed.value["loggedIn"] == .bool(true), parsed.value["authMethod"] == .str("oauth_token"),
              parsed.value["apiProvider"] == .str("firstParty"),
              parsed.value["configDirectory"] == .str(expectedConfig) else { throw Refused.firstPartySubscriptionRequired }
    }
}
