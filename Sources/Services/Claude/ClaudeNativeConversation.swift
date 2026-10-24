import Brains
import Foundation

/// All effective local checks precede a person/binder turn. The only initial model request when the
/// person presses Enable is a fixed data-free canary, through the same launch and framing contract.
enum ClaudeNativeConversation {
    static func driver(program: URL, support: URL, credential: String, connection: UUID, session: UUID,
                       policy: String, onSpawn: @escaping @Sendable (Int32) throws -> Void) async throws -> ClaudeConversationRuntime.Driver {
        let prepared = try ClaudeReadLaunch.prepare(program: program, support: support, connectionID: connection,
                                                   sessionID: session, credential: credential, policy: policy, onSpawn: onSpawn)
        try await ClaudeReadAccount.verify(prepared)
        let runner = ClaudeReadOnlyTurn(launch: prepared.launch,
            limits: try .init(inactivity: .seconds(90), overall: .seconds(240), terminationGrace: .seconds(2)))
        return .init(run: { line, resume in
            switch try await runner.run(line, resume: resume) {
            case .text(let text): return text
            case .interrupted: return nil
            }
        }, stop: { runner.stop() }, exited: { runner.processExitConfirmed }, hash: prepared.programHash)
    }
}
