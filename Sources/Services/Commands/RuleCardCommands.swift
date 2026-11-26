import BinderFormat
import BinderStore
import Foundation
import SpravaKit

/// The rule cards Sprava itself wrote (decisions.md D46), by binder and card id, in `learning/rule-cards.json`. Only these
/// are accepted as rules: a card that holds a rule but came another way never writes to a binder's instructions.
struct RuleCardRecord {
    let file: URL
    init(support: URL) { file = support.appendingPathComponent("learning/rule-cards.json") }

    func contains(_ key: String) -> Bool { keys().contains(key) }

    func record(_ key: String) throws {
        var all = keys()
        guard !all.contains(key) else { return }
        all.append(key)
        // The newest thousand: an older card that was never accepted is not offered again.
        let kept = Array(all.suffix(1000))
        try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
        try AtomicFile.write(Data(JSONWriter.compact(.array(kept.map(JSONValue.string))).utf8), to: file)
    }

    private func keys() -> [String] {
        guard case .ok(let data) = SafeFile.read(file, limit: 1 << 20), let value = try? JSONParser.parse(data).value else { return [] }
        return value.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension Commands {
    /// Records a rule card Sprava wrote, so it can be accepted as one. Its writer calls this once the card is saved and trusted.
    public func recordRuleCard(_ id: String, in folder: URL) throws {
        try RuleCardRecord(support: support).record(key(folder, id))
    }

    /// `accept_rule`: `{binder, proposal, digest, rule?}`. Accepts a rule card: the rule, or the person's edit of it
    /// (`rule`), goes into the binder's instructions as a dated line under `## Learned rules`, by the save the
    /// Instructions tab uses (the digest check, the atomic write, Undo last save), and the card is applied. The save comes
    /// first: a card applied with no rule written would lose what the person accepted, and an accept tried again after
    /// the save adds nothing twice. Answers `{digest}`, the instructions' digest now.
    ///
    /// Refused, with what to do: while the instructions on disk are not the ones the person last saved or confirmed (a
    /// save would accept that text too), and when the rule does not fit.
    ///
    /// A card that rewrites the whole section (`RulesRewrite`) is accepted here too, as shown, with no edit: everything
    /// under the heading is replaced by its lines. It is refused when the section no longer holds the lines the card
    /// showed as there now, unless it already holds the new ones, which is an accept tried again after its save.
    func acceptRule(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        guard case .string(let id)? = r["proposal"], case .string(let seen)? = r["digest"] else {
            throw Failure(message: "accept_rule needs proposal and digest")
        }
        if let edit = r["rule"], edit.stringValue == nil { throw Failure(message: "rule must be text; nothing was accepted") }
        let teka = Teka.read(f)
        guard teka.isAdopted else { throw Failure(message: "this binder is not adopted yet") }
        guard !teka.writesBlocked else { throw Failure(message: "this binder's writes are blocked until it is repaired; nothing was accepted") }
        guard let recorded = try loadDigests()[key(f, id)] else { throw Failure(message: "this card was not written by Sprava, so it cannot be accepted") }
        guard recorded == seen else { throw Failure(message: "this card changed since it was shown; reload it") }
        let proposal = try ProposalStore.load(id, in: f, expectedDigest: recorded)
        let card = RuleCard(proposal), rewrite = card == nil ? RulesRewrite(proposal) : nil
        guard card != nil || rewrite != nil, RuleCardRecord(support: support).contains(key(f, id)) else {
            throw Failure(message: "this card holds no rule Sprava wrote, so it cannot be accepted; nothing was changed")
        }
        guard proposal.state == "proposed" else { throw Failure(message: "this card is \(proposal.state), so nothing was accepted") }
        let rule = r["rule"]?.stringValue ?? card?.rule
        if let rewrite {
            guard r["rule"] == nil else { throw Failure(message: "a rewrite of the rules is accepted as shown; change the rules on the Instructions tab. Nothing was accepted") }
            do { _ = try rewrite.checked() } catch { throw Failure(message: "\(error) Nothing was accepted.") }
        } else if let problem = LearnedRules.problem(rule ?? "") { throw Failure(message: problem + " Nothing was accepted.") }

        let instructions: BinderInstructions
        switch BinderInstructions.read(f) {
        case .success(let found): instructions = found
        case .failure(let problem): throw Failure(message: problem.description)
        }
        // Text nobody confirmed in the app is not followed (binder-instructions.md §2). Saving would record all of it as
        // accepted, so the person confirms it first. Nothing but white space is nothing to confirm.
        guard instructions.isAccepted || instructions.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "This binder's instructions changed outside Sprava and were not confirmed. Open Instructions, read them and save; then accept this rule.")
        }
        let text: String
        if let rewrite {
            if LearnedRules.holds(rewrite.rules, in: instructions.text) {
                text = instructions.text
            } else {
                guard LearnedRules.section(of: instructions.text) == rewrite.replaces else {
                    throw Failure(message: "The learned rules changed since this was proposed, so the card no longer shows what it would replace. Dismiss it; nothing was changed.")
                }
                text = LearnedRules.replacing(with: rewrite.rules, on: today, in: instructions.text)
            }
        } else {
            text = LearnedRules.adding(rule ?? "", on: today, to: instructions.text)
        }
        guard BinderInstructions.fits(text) else {
            throw Failure(message: "This binder's instructions are full (\(BinderInstructions.maxCharacters) characters). Shorten them on the Instructions tab, then accept this rule.")
        }
        let digest: String
        do {
            digest = try BinderInstructions.save(text, expected: instructions.digest, in: f)
        } catch let refused as BinderInstructions.Refused {
            throw Failure(message: refused == .changed ? "This binder's instructions changed just now, so nothing was accepted. Try again." : refused.description)
        }
        _ = try TekaStore(folder: f, client: client).approve(proposal, edited: nil, now: now)
        try recordDigests([id], in: f)
        return JSONObject([(key: "digest", value: .string(digest))])
    }
}
