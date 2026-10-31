import Brains
import Foundation

/// Fixed diagnostics only. Provider output, credential bytes and native stderr never cross into the UI.
public enum ClaudeSetupFailure: String, Error, Sendable, CaseIterable {
    case installation, managedPolicy, tokenFormat, rejectedToken, privateHome, account, protocolMismatch, timeout, firstReply, resume, keychain, unavailable

    public var message: String {
        switch self {
        case .installation: "Sprava needs Anthropic's signed native Claude Code executable. A shell wrapper or aiq shim cannot be used here. Choose the native installation."
        case .managedPolicy: "A managed Claude policy is installed on this Mac. Sprava cannot verify an isolated connection with that policy present."
        case .tokenFormat: "The token contains spaces or line breaks. Paste only the token printed by setup-token."
        case .rejectedToken: "Anthropic rejected this subscription token. Use Copy Command to generate a fresh token with the selected native Claude installation, then try again."
        case .privateHome: "Sprava could not prepare Claude's private working folder. No account was enabled."
        case .account: "Claude did not confirm a private subscription connection. Generate a subscription token with the selected native Claude executable, then try again."
        case .protocolMismatch: "The installed Claude Code did not match Sprava's supported conversation protocol. This is a compatibility failure, not evidence that your token is invalid."
        case .timeout: "Claude verification timed out. Refresh to check whether it finished before trying again."
        case .firstReply: "Claude could not complete the connection check. Check network access and subscription availability, then try again. Your account has not been enabled."
        case .resume: "Claude answered, but the second connection check did not receive the current app context. Your token may still be valid."
        case .keychain: "Claude verification passed, but Sprava could not save the token in your Keychain. Unlock the login Keychain and allow Sprava access, then try again."
        case .unavailable: "Sprava could not finish Claude setup. Refresh the background connection before trying again."
        }
    }

    static func classify(_ error: Error, stage: Self) -> Self {
        if let issue = error as? Self { return issue }
        if let issue = error as? ClaudeReadLaunch.Refused {
            switch issue {
            case .unsupportedInstallation: return .installation
            case .managedPolicy: return .managedPolicy
            case .unsafeHome: return .privateHome
            case .invalidInput: return .tokenFormat
            }
        }
        if error is ClaudeReadAccount.Refused { return .account }
        if let issue = error as? ClaudeReadOnlyTurn.Failure {
            switch issue {
            case .protocolMismatch: return .protocolMismatch
            case .authentication: return .rejectedToken
            case .deadline: return .timeout
            default: return stage
            }
        }
        return stage
    }
}
