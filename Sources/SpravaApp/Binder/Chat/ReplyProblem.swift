import Services

/// What a reply that did not finish offers the person. No action sends anything: sending the same words again could repeat
/// a change the reply already made, so the words go back in the box and the person looks first.
struct ReplyProblem: Equatable {
    enum Action: Equatable { case checkReply, editAndSend, openAssistant, restart }

    var level: NoticeLevel
    var actions: [Action]
    /// Sprava does not know how the reply ended: it may still be running, and any changes reach the page only with its
    /// result, so an empty list of changes proves nothing.
    var outcomeUnknown = false

    static let lostTouch = ReplyProblem(level: .needsYou, actions: [.checkReply], outcomeUnknown: true)

    init(level: NoticeLevel, actions: [Action], outcomeUnknown: Bool = false) {
        self.level = level; self.actions = actions; self.outcomeUnknown = outcomeUnknown
    }

    init(_ failure: ChatCommandFailure) {
        switch failure {
        case .unavailable: self = .lostTouch
        case .turnFailed(let reason, _):
            switch reason {
            case "exit_unconfirmed": self.init(level: .broken, actions: [.restart])
            case "authentication", "token_missing", "setup": self.init(level: .broken, actions: [.openAssistant, .editAndSend])
            case "usage_limit", "no_quota", "protocol": self.init(level: .needsYou, actions: [.openAssistant, .editAndSend])
            case "binder_unavailable": self.init(level: .needsYou, actions: [])
            default: self.init(level: .needsYou, actions: [.editAndSend])
            }
        case .invalidRequest, .busy, .cancelled: self.init(level: .needsYou, actions: [.editAndSend])
        }
    }

    /// The Notice's two sentences for this reply.
    func words(for entry: BinderChat.Entry) -> (title: String, detail: String) {
        if outcomeUnknown {
            return ("Sprava lost touch with this reply.",
                    "It may still be running, and it may already have made changes. Check Reply looks for its result.")
        }
        var detail = ""
        if case .failed(let why) = entry.state { detail = why }
        if !entry.changes.isEmpty || entry.changesCut {
            detail += (detail.isEmpty ? "" : " ") + "This reply may already have made changes. Look at them before sending again."
        }
        return ("This reply did not finish.", detail)
    }
}
