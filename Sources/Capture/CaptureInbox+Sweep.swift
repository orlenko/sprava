import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Sweeping the capture folder and ingesting each complete event (capture-event-v0 §5.3, architecture 8).
extension CaptureInbox {
    /// One pass: list every device folder, diff against the cursor, ingest what is complete.
    public func sweep(binders: [ShelfRow], commands: Commands, now: Date = Date()) -> SweepResult {
        var result = SweepResult()
        guard SafeFile.isTrustedFolder(root) else {
            if FileManager.default.fileExists(atPath: root.path) { result.refusedFolders += 1 }
            return result
        }
        // A cursor, registry or digest list that cannot be read stops the sweep: rebuilt, it would card every
        // capture again and save over what is there (capture-event-v0 §5.3).
        var state: State
        let producers: [String: String]
        let notices: [String: String]
        do {
            state = try readState()
            producers = try readProducers()
            _ = try unfiledDigests()
            notices = try self.notices()
        } catch {
            result.unreadable = (error as? ShelfStore.Unreadable).map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "capture state"
            journal([("stage", .str("state_unreadable"))])
            return result
        }
        let fm = FileManager.default
        // A card the person filed just before a crash leaves its Inbox copy behind; it goes now.
        dropFiled(binders: binders, commands: commands)
        // A binder back after it could not be reached first gets the capture work it missed.
        settleDeferred(binders, state: &state, commands: commands, now: now)
        // Privacy debts are paid first, as far as they can be.
        payDebts(binders, state: &state, commands: commands, now: now)
        // A hand-off to the clerk's cards cut short is finished or taken back, so no capture waits twice.
        settleHandoffs(state: &state, commands: commands, now: now)
        lookForMissingMedia(state: &state)
        guard let devices = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            if (try? save(state)) == nil { result.unsaved = "state.json" }
            return result
        }
        devices: for device in devices.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !device.lastPathComponent.hasPrefix(".") {
            let deviceName = device.lastPathComponent
            guard SafeFile.isTrustedFolder(device) else {
                if (try? device.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { result.refusedFolders += 1 }
                continue
            }
            // A folder that cannot be listed now is out of reach, not empty: Health counts it.
            guard let names = try? fm.contentsOfDirectory(atPath: device.path) else { result.refusedFolders += 1; continue }
            for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let file = device.appendingPathComponent(name)
                let stem = String(name.dropLast(5))
                // The journal names an event only by a valid id; any other file name may be the person's words.
                let logged: JSONValue = CaptureEvent.isUUIDText(stem) ? .string(stem) : .str("invalid-name")
                // An id still at "ingested" crashed before its card was made, and one at "retracting" has a part of
                // its retraction left to do: either is picked up again here.
                if let stage = state.ingested[stem], stage != "ingested", stage != "retracting" { continue }
                let key = deviceName + "/" + name
                var st = stat()
                guard lstat(file.path, &st) == 0 else { continue }
                let size = Int(st.st_size)
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                // A file deferred by a reader that knew fewer format versions is read again (capture-event-v0 §5.3).
                if let seen = state.examined[key], seen.size == size, seen.mtime == mtime, seen.outcome != "pending",
                   !seen.outcome.hasPrefix("deferred") || seen.outcome == Self.deferredOutcome { continue }
                var (check, event) = CaptureEvent.check(file, deviceFolder: device)
                if case .complete(.capture) = check, let e = event, let expected = producers[deviceName], e.app != expected {
                    check = .quarantined("source.app does not match the folder's registered producer")
                    event = nil
                }
                // The app sends its notice around the moment it publishes; an own-folder note without one waits a
                // few seconds, so the binder the person chose is not lost to a sweep that ran first (architecture 8).
                if case .complete(.capture) = check, producers[deviceName] == "sprava", let e = event, notices[e.id] == nil {
                    let age = now.timeIntervalSince1970 - mtime
                    if age > -60 && age < 10 {
                        result.pending += 1
                        state.examined[key] = .init(size: size, mtime: mtime, outcome: "pending")
                        continue
                    }
                }
                switch check {
                case .pending:
                    result.pending += 1
                    state.examined[key] = .init(size: size, mtime: mtime, outcome: "pending")
                case .deferred:
                    state.examined[key] = .init(size: size, mtime: mtime, outcome: Self.deferredOutcome)
                    journal([("event", logged), ("stage", .str("newer_format"))])
                case .quarantined(let why):
                    result.quarantined += 1
                    // Recorded as examined only once its copy and reason are kept, so Health never loses it.
                    if quarantine(file, device: deviceName, reason: why) { state.examined[key] = .init(size: size, mtime: mtime, outcome: "quarantined") }
                    journal([("event", logged), ("stage", .str("quarantined")), ("reason", .string(why))])
                case .complete(.derived):
                    state.ingested[stem] = "derived"
                case .complete(.capture):
                    guard let event else { continue }
                    state.paths = (state.paths ?? [:]).merging([stem: key]) { $1 }
                    ingest(event, device: deviceName, producer: producers[deviceName], notice: notices[stem], size: size,
                           state: &state, result: &result, binders: binders, commands: commands, now: now)
                    // Media that never arrived are marked missing and looked for again on every sweep (§5.3).
                    if !event.missingMedia.isEmpty, state.ingested[stem] != nil, state.missingMedia?[stem] == nil {
                        state.missingMedia = (state.missingMedia ?? [:]).merging([stem: event.missingMedia]) { $1 }
                        journal([("event", logged), ("stage", .str("media_missing")), ("files", .int(event.missingMedia.count))])
                    }
                    // A cursor that cannot be written stops the sweep: nothing more is made that it would not hold.
                    if result.unsaved != nil { break devices }
                }
            }
        }
        // Work a binder missed that waited for an event this sweep finished is done now, not a sweep later.
        if result.unsaved == nil {
            settleDeferred(binders, state: &state, commands: commands, now: now)
            payDebts(binders, state: &state, commands: commands, now: now)
        }
        if (try? save(state)) == nil { result.unsaved = "state.json" }
        return result
    }

    /// Looks again for media an event was taken in without: once every one is there at its size, it is no longer
    /// marked missing.
    func lookForMissingMedia(state: inout State) {
        for (id, files) in state.missingMedia ?? [:] {
            guard let device = state.paths?[id]?.split(separator: "/").first.map(String.init) else { continue }
            let folder = root.appendingPathComponent(device, isDirectory: true)
            let arrived = files.allSatisfy { path, bytes in
                var st = stat()
                return lstat(folder.appendingPathComponent(path).path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && Int(st.st_size) == bytes
            }
            guard arrived else { continue }
            state.missingMedia?[id] = nil
            journal([("event", .string(id)), ("stage", .str("media_arrived"))])
        }
    }

    /// Ids of events taken in with media still missing (capture-event-v0 §5.3).
    package func eventsMissingMedia() -> [String] { (loadState().missingMedia ?? [:]).keys.sorted() }

    /// How a deferred file is recorded: with the format versions this reader knows, so a reader that knows more
    /// reads it again. Change it whenever `CaptureEvent.check` learns a new `format_version`.
    static let deferredOutcome = "deferred:0"

    func ingest(_ event: CaptureEvent, device: String, producer: String?, notice: String?, size: Int, state: inout State,
                result: inout SweepResult, binders: [ShelfRow], commands: Commands, now: Date) {
        let id = event.id
        let textHash = CaptureInbox.digest(Data(event.text.utf8))
        // Only a registered producer's own events can change a chain (architecture 8; capture-event-v0 §3.2). An event
        // from another folder that repeats the app, ref and revision of an event of a registered chain is the same
        // capture: it belongs to that chain, so whatever the chain does later (a raise to private, a correction, a
        // retraction) reaches its card too.
        let registered = producer != nil && producer == event.app
        let registeredChain = state.chainsByKey?[event.chainKey] ?? []
        let member = registered || registeredChain.contains(id) || state.captures?[event.dedupeKey].map { first in
            first != id && registeredChain.contains(first)
        } == true
        let new = state.ingested[id] == nil
        var earlierCopy = new ? earlierCapture(event, state: state) : nil
        let clock = state.clocks?[id] ?? Self.clockKey(event)
        // An earlier event with the same app, ref and revision that crashed before its card was made (and got none)
        // holds nothing yet, so this one is no duplicate of it: it is ingested by its own stamp. That also keeps a
        // second retraction, which repeats the triple of the first, from being taken for a copy of one left
        // unfinished. The earlier one, when its sweep is finished, is stale or the same words as this one.
        if let earlier = earlierCopy, earlier != id, state.ingested[earlier] == "ingested",
           !adoptOrphanCard(earlier, chain: member ? chainIDs(of: event, state: state) : [], state: &state, binders: binders, commands: commands, now: now) {
            earlierCopy = nil
        }
        var chain = member ? chainIDs(of: event, state: state).filter { $0 != id } : []
        // An event from another folder with this registered event's app, ref and revision, taken in before it, joins
        // the chain now (before it is decided whether this one repeats it): whatever the chain does later reaches its
        // card, and a raise to private it carries reaches the chain.
        // Every such event joins, not only the one the dedupe key names now: two copies from other folders can each have
        // been carded before this one arrived.
        var absorbed: [String] = []
        if registered {
            let paths = state.paths ?? [:]
            let same = (state.keyEvents?[event.chainKey] ?? []).filter { e in
                storedEvent(e, paths: paths)?["source"]?["revision"]?.stringValue == event.revision
            } + [earlierCapture(event, state: state)].compactMap { $0 }
            for first in same where first != id && !chain.contains(first) && !absorbed.contains(first) && state.ingested[first] != nil {
                chain.insert(first, at: 0)
                absorbed.append(first)
                if Set(state.privates ?? []).contains(first), chain.count > 1 {
                    raise(chain.filter { $0 != first }, for: first, key: event.chainKey, state: &state, binders: binders, commands: commands, now: now)
                }
            }
        }
        // A raise to private only ever makes more private, so it reaches every event of the same app and ref, from any
        // folder, even one that cannot change that chain otherwise (capture-event-v0 §3.3).
        if new { state.keyEvents = (state.keyEvents ?? [:]).merging([event.chainKey: (state.keyEvents?[event.chainKey] ?? []) + [id]]) { $1 } }
        let sameKey = (state.keyEvents?[event.chainKey] ?? []).filter { $0 != id }
        let privacyChain = (member ? chain : registeredChain.filter { $0 != id }) + sameKey.filter { !chain.contains($0) && !registeredChain.contains($0) }
        // And it holds for the events of that app and ref that come only later: a private event remembers its key, and
        // every event with that key is private from then on (capture-event-v0 §3.3).
        if event.isPrivate, !(state.privateKeys ?? []).contains(event.chainKey) {
            state.privateKeys = (state.privateKeys ?? []) + [event.chainKey]
        }
        if (state.privateKeys ?? []).contains(event.chainKey) { markPrivate(chain + [id], state: &state) }
        // The current event of a chain is the one that counts most (`rank`: a producer's own revision over an
        // approximation, then the highest HLC; capture-event-v0 §3.2): a revision that counts less changes nothing. Duplicates count here: a second retraction taken for a copy of the first, because the
        // restore between them had not arrived yet, still makes that restore stale when it does.
        // An `approx:` revision never outranks a producer's own (`rank`).
        if event.revision.hasPrefix("approx:"), !(state.approx ?? []).contains(id) { state.approx = (state.approx ?? []) + [id] }
        let mine = Self.rank(clock: clock, approx: event.revision.hasPrefix("approx:"))
        func ranked(_ e: String) -> String { Self.rank(e, state: state) }
        let current = Self.counting(chain, state: state)
        // What this revision is compared with is the newest event whose words are held by a card or a settled stage.
        // One that crashed before its card was made, or a stale revision, holds nothing, so its words are never
        // taken as already filed (§3.2, §5.3).
        let holding = chain.filter { holdsContent($0, chain: chain + [id], state: &state, binders: binders, commands: commands, now: now) }
        // An event of the chain a crash left unfinished may have a card no listing could see now: what this one is
        // compared with is not known, so it waits for a sweep that can see every card (it is not taken in yet).
        if chain.contains(where: { state.ingested[$0] == "ingested" }), !cardsListedCompletely(binders: binders, deviceID: commands.deviceID) {
            journal([("event", .string(id)), ("stage", .str("cards_unreadable"))])
            result.pending += 1
            return
        }
        let baseline = Self.counting(holding, state: state)
        let currentRetracted = baseline.map { ["retracted", "retracting"].contains(state.ingested[$0] ?? "") } ?? false
        // A deletion after the chain's current event, or a restore after its deletion, changes what the chain is:
        // neither repeats an earlier event of the same triple, so neither is taken for a duplicate (§3.2).
        let transition = baseline.map { ranked($0) < mine } == true && event.retracted != currentRetracted

        if new {
            if let earlier = earlierCopy, !transition {
                // The same capture again: only a raise of sensitivity is applied (capture-event-v0 §3.2).
                result.duplicates += 1
                state.ingested[id] = "duplicate"
                state.dupOf = (state.dupOf ?? [:]).merging([id: earlier]) { $1 }
                state.clocks = (state.clocks ?? [:]).merging([id: clock]) { $1 }
                // A registered event that repeats one from another folder brings that one, and its card, into the chain.
                let members = chain.contains(earlier) ? chain : [earlier] + chain
                if member { state.chainsByKey = (state.chainsByKey ?? [:]).merging([event.chainKey: members + [id]]) { $1 } }
                // The copy was carded while it was not yet in the chain, so its card and the chain's were never compared:
                // whichever words do not stand for the chain now wait on cards that are out of date, and they go, as a
                // correction would have taken them. What stands is the newest event holding words, a duplicate counted
                // as the event it repeats (a retraction taken for a copy of an earlier one ends the chain after the copy).
                let standing = Self.standing(members + [id], state: state)
                let retractedNow = standing.map { ["retracted", "retracting"].contains(state.ingested[$0] ?? "") } ?? false
                let outdated = standing.map { s in members.filter { $0 != s && state.texts?[$0] != state.texts?[s] } } ?? []
                // A binder out of reach now gets this when it is back, worked out from the chain as it is then.
                if registered, !absorbed.isEmpty { deferWork(of: id, chain: members, binders: binders, commands: commands, state: &state) }
                if registered, !absorbed.isEmpty, !outdated.isEmpty {
                    let words: Replacement? = retractedNow ? .carried(nil) : standing.map { s in self.words(s, chain: members + [id], state: state).map { .carried($0) } } ?? .carried(nil)
                    if !withdraw(chain: outdated, reason: "replaced by a corrected note", keeping: retractedNow ? standing : nil, replacement: words,
                                 state: &state, binders: binders, commands: commands, now: now) {
                        // Left for each binder this Mac writes, finished there by the next sweep or before an approval.
                        owe(id, binders: binders, commands: commands, state: &state)
                    }
                }
                // Sensitivity only goes up, whoever sends it: a private copy raises what the copy repeats (§3.3).
                if event.isPrivate {
                    let raised = members + privacyChain.filter { !members.contains($0) }
                    raise(raised, for: id, key: event.chainKey, state: &state, binders: binders, commands: commands, now: now)
                }
                journal([("event", .string(id)), ("stage", .str("duplicate")), ("of", .string(earlier))])
                return
            }
            state.ingested[id] = "ingested"
            state.captures = (state.captures ?? [:]).merging([event.dedupeKey: id]) { $1 }
            state.apps[id] = event.app
            state.texts = (state.texts ?? [:]).merging([id: textHash]) { $1 }
            state.clocks = (state.clocks ?? [:]).merging([id: clock]) { $1 }
            // The file's digest as taken in: the clerk later reads it again and must find the same bytes.
            state.eventDigests = (state.eventDigests ?? [:]).merging([id: event.digest]) { $1 }
            if member { state.chainsByKey = (state.chainsByKey ?? [:]).merging([event.chainKey: chain + [id]]) { $1 } }
        }
        // A private event's chain owes its privacy pass from the save that first holds the event, so no crash after it
        // loses the debt (cleared only once paid in full).
        if event.isPrivate, !privacyChain.isEmpty {
            markPrivate(privacyChain + [id], state: &state)
            owePrivacy(event.chainKey, state: &state)
        }
        // Ingesting is one durable step, recorded before anything else happens: no card is made from an event the
        // cursor on disk does not hold, since a card the cursor forgot would be made again (§5.3).
        guard checkpoint(state, &result) else { return }
        // A binder that cannot be reached now misses what this event does to its chain; it is done there when it is back.
        if member, !chain.isEmpty { deferWork(of: id, chain: chain, binders: binders, commands: commands, state: &state) }
        if new {
            journal([("event", .string(id)), ("stage", .str("ingested")), ("bytes", .int(size))])
            result.ingested += 1
        }

        // Sensitivity only goes up, whatever order a chain's events arrive in: a private event raises the chain even
        // when it is stale, empty or a retraction (§3.3).
        // The first event of a chain records its privacy too, before any return below (empty, retracted), so a later
        // revision marked otherwise is still filed private.
        if event.isPrivate {
            if !privacyChain.isEmpty { raise(privacyChain, for: id, key: event.chainKey, state: &state, binders: binders, commands: commands, now: now) }
            else { markPrivate([id], state: &state) }
        }
        // A revision that arrives late but is older than what the chain already has changes nothing else.
        if let current, ranked(current) > mine {
            // A retraction left part done still finishes its part: what waits from the events before it goes, and what
            // was filed from them is offered for removal. Nothing of the later events is touched.
            if state.ingested[id] == "retracting" {
                let before = chain.filter { ranked($0) < mine }
                let done = retract(chain: before, retraction: id, state: &state, binders: binders, commands: commands, now: now)
                state.ingested[id] = done ? "retracted" : "retracting"
                journal([("event", .string(id)), ("stage", .str(done ? "retracted" : "retract_failed"))])
                return
            }
            // One taken in before a crash may have a card of its own words waiting already; the chain has moved past
            // them, so it goes. When the cards cannot all be seen now, the stage stays "ingested" until they can.
            if !new {
                guard cardsListedCompletely(binders: binders, deviceID: commands.deviceID) else {
                    journal([("event", .string(id)), ("stage", .str("cards_unreadable"))])
                    return
                }
                let own = withdrawable(chain: [id], binders: binders, deviceID: commands.deviceID).filter { $0.1.raw["provenance"]?["events"] == .array([.string(id)]) }
                guard let words = currentWords(chain, state: state),
                      withdraw(own, reason: "replaced by a corrected note", replacement: words, state: state, binders: binders, commands: commands, now: now) else { return }
            }
            state.ingested[id] = "stale_revision"
            journal([("event", .string(id)), ("stage", .str("stale_revision"))])
            return
        }
        // A later revision with no words, of a chain whose words are held, says none of them any more: like a retraction,
        // what waits from the chain is withdrawn and what was filed from it is offered for removal. Only a chain that
        // held nothing yet takes the shortcut below. (A document whose text could not be read comes through intake,
        // never as a revision of a chain, so it never empties one.)
        let emptied = !event.retracted && event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && baseline != nil && !currentRetracted
        if event.retracted || emptied {
            // Every part of a retraction is done, or the stage says so and the next sweep does the rest.
            let done = chain.isEmpty || retract(chain: chain, retraction: id, state: &state, binders: binders, commands: commands, now: now)
            state.ingested[id] = done ? "retracted" : "retracting"
            journal([("event", .string(id)), ("stage", .str(done ? (emptied ? "emptied" : "retracted") : "retract_failed"))])
            return
        }
        if event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.ingested[id] = "nothing_to_file"
            return
        }
        // A chain raised to private stays private for every card made from it later (§3.3).
        let filedAs = Self.asFiled(event, privates: Set(state.privates ?? []), chain: chain)
        if filedAs.isPrivate { markPrivate([id], state: &state) }
        // Verification (architecture 8): Sprava's own folder needs a matching notice; an unregistered folder is
        // unverified; a hint is honoured only from a verified note of Sprava's own. Every card made from the event
        // says when its source is unverified.
        let own = producer == "sprava"
        let verified = own ? notice == event.digest : producer != nil
        let hint = own && verified ? event.binderHint : nil
        // A later event of the chain: the same text changes only sensitivity; other text replaces what still waits.
        // A restore after a deletion is new content to review, since what was filed may be dropped by now (§3.2).
        var replaces: String?
        if let earlier = baseline, !currentRetracted {
            if state.texts?[earlier] == textHash {
                state.ingested[id] = "same_text"
                journal([("event", .string(id)), ("stage", .str("same_text"))])
                return
            }
            replaces = earlier
            // Items already filed from the earlier version get a change card, never new items beside them (§6.5). What
            // waits from the chain is withdrawn only once those cards are kept: when one cannot be saved or trusted,
            // nothing changed, the stage stays "ingested", and the next sweep tries again from the same place.
            // The change cards carry over what the waiting cards held, so they are made only once every card can be read:
            // one missed now would lose its lines for good. Until then the stage stays "ingested".
            guard cardsListedCompletely(binders: binders, deviceID: commands.deviceID) else {
                journal([("event", .string(id)), ("stage", .str("cards_unreadable"))])
                return
            }
            let withdrawing = withdrawable(chain: chain, binders: binders, deviceID: commands.deviceID)
            let corrections: [(URL?, String)]?
            do {
                corrections = try correctionCards(filedAs, chain: chain, current: earlier, withdrawn: withdrawing, paths: state.paths ?? [:],
                                                  verified: verified, binders: binders, commands: commands, now: now)
            } catch {
                journal([("event", .string(id)), ("stage", .str("card_failed")), ("code", .string("\(type(of: error))"))])
                return
            }
            if let made = corrections {
                // What waits from the earlier words must go, once what it holds of the new words is carried (the
                // change cards above, or a card the gate makes where it waited); when some of it cannot go (its binder
                // is read-only now), the stage stays "ingested" and the next sweep tries again: the cards this
                // correction made are found again, never made twice.
                let current: Replacement? = words(id, text: event.text, chain: chain + [id], state: state).map { .carried($0) }
                guard withdraw(chain: chain, reason: "replaced by a corrected note", replacement: current, state: &state, binders: binders,
                               commands: commands, now: now) else {
                    journal([("event", .string(id)), ("stage", .str("withdraw_failed"))])
                    return
                }
                if let (folder, card) = made.first {
                    state.cards[id] = card
                    if let folder { state.cardBinder = (state.cardBinder ?? [:]).merging([id: folder.path]) { $1 } }
                    result.filed += 1
                }
                state.clerk = (state.clerk ?? [:]).merging([id: "kept"]) { $1 }   // the clerk would add them again
                state.ingested[id] = made.isEmpty ? "nothing_to_change" : "proposed"
                journal([("event", .string(id)), ("stage", .str("correction_proposed")), ("cards", .int(made.count))])
                _ = checkpoint(state, &result)
                return
            }
        }

        let made: (String, URL?)
        do {
            // A card made before a crash, whose id never reached the cursor, is kept, never made twice (§5.3).
            made = try orphanCard(id, binders: binders, commands: commands, now: now)
                ?? card(for: filedAs, hint: hint, verified: verified, producer: producer ?? event.app,
                        replaces: replaces, binders: binders, commands: commands, now: now)
        } catch {
            // The stage stays "ingested", so the next sweep makes the card.
            journal([("event", .string(id)), ("stage", .str("card_failed")), ("code", .string("\(type(of: error))"))])
            return
        }
        let (proposalID, filedTo) = made
        state.cards[id] = proposalID
        if let filedTo { state.cardBinder = (state.cardBinder ?? [:]).merging([id: filedTo.path]) { $1 } }
        if let hint, filedTo != nil { state.hints = (state.hints ?? [:]).merging([id: hint]) { $1 } }
        // The clerk reads it next; private captures too, on the device.
        state.clerk = (state.clerk ?? [:]).merging([id: "pending"]) { $1 }
        state.ingested[id] = filedTo == nil ? "unfiled" : "proposed"
        // A new revision of a chain with nothing filed: its own card reads all its words, and what waits from the
        // earlier ones gives way to it from the same save on, as work owed to every place (finished at the end of the
        // sweep, or when a binder out of reach is back).
        if replaces != nil {
            owe(id, binders: binders, commands: commands, state: &state)
            for e in chain where state.clerk?[e] != nil { state.clerk?[e] = "superseded" }
        }
        _ = checkpoint(state, &result)   // the card's id reaches the cursor now, not at the end of the sweep
        if filedTo == nil { result.unfiled += 1 } else { result.filed += 1 }
        if let end = event.endedAt { result.latencies.append(max(0, now.timeIntervalSince(end))) }
        journal([("event", .string(id)), ("stage", .str(filedTo == nil ? "unfiled" : "proposed")), ("tier", .str("0")),
                 ("verified", .bool(verified))])
    }

    /// Saves the cursor mid-sweep. One that cannot be written is reported, and the sweep stops (§5.3).
    func checkpoint(_ state: State, _ result: inout SweepResult) -> Bool {
        guard (try? save(state)) == nil else { return true }
        if result.unsaved == nil { journal([("stage", .str("state_unwritable"))]) }
        result.unsaved = "state.json"
        return false
    }

    /// The Tier 0 card event `id` got before a crash kept its id from the cursor: one still waiting, unfiled or in a
    /// binder, or one the person already approved or rejected; nil when there is none. A card waiting in a binder counts
    /// only when it is trusted: one saved but whose digest was never kept (the crash came in between) could never be
    /// approved, so it is taken back here, and the event's card is made again from the event as checked now.
    func orphanCard(_ id: String, binders: [ShelfRow], commands: Commands, now: Date) -> (String, URL?)? {
        // Only a card of this event's own words: made from it alone, and not one that only redacts or removes (a raise
        // or a retraction of its chain names every event of the chain).
        // A correction's cards are no Tier 0 card: they are made before the cards they replace are withdrawn, so the
        // event they came from is finished by its own sweep (which finds them again), never adopted here.
        func own(_ p: Proposal) -> Bool {
            p.raw["provenance"]?["events"] == .array([.string(id)]) && !Self.onlyRedacts(p) && p.raw["provenance"]?["retraction"] == nil
                && p.raw["provenance"]?["supersedes"]?.arrayValue == nil
        }
        let (waitingUnfiled, waitingFiled) = pendingCards(chain: [id], binders: binders, deviceID: commands.deviceID)
        if let p = waitingUnfiled.first(where: own) { return (p.id, nil) }
        var trusted: (URL, Proposal)?
        for (folder, p) in waitingFiled where own(p) {
            if commands.isTrusted(p.id, in: folder) {
                if trusted == nil { trusted = (folder, p) }
            } else {
                try? TekaStore(folder: folder).reject(p, reason: "its digest could not be kept", now: now)
            }
        }
        if let (folder, p) = trusted ?? actedOnCard(id, binders: binders, deviceID: commands.deviceID) { return (p.id, folder) }
        return nil
    }

    /// Records in the cursor the card an event at "ingested" got before a crash, as its own sweep would have; false
    /// when it has none. The clerk reads the event next. A private event raises its chain as its own sweep would have,
    /// since that sweep's record of the raise was lost with the crash (capture-event-v0 §3.3).
    func adoptOrphanCard(_ id: String, chain: [String], state: inout State, binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        guard state.ingested[id] == "ingested", let (card, folder) = orphanCard(id, binders: binders, commands: commands, now: now) else { return false }
        state.cards[id] = card
        if let folder { state.cardBinder = (state.cardBinder ?? [:]).merging([id: folder.path]) { $1 } }
        state.clerk = (state.clerk ?? [:]).merging([id: "pending"]) { $1 }
        state.ingested[id] = folder == nil ? "unfiled" : "proposed"
        // A revision's own card replaces what waits from the earlier words: that is owed to every place, as its sweep
        // would have recorded it.
        if chain.contains(where: { $0 != id }) { owe(id, binders: binders, commands: commands, state: &state) }
        journal([("event", .string(id)), ("stage", .str("card_recovered"))])
        let stored = storedEvent(id, paths: state.paths ?? [:])?["sensitivity"]
        let carded = (folder.map { f in ProposalStore.list(in: f).map(\.0) } ?? unfiled()).first { $0.id == card }
        if stored.map({ $0 != .str("unmarked") }) ?? false || carded?.raw["provenance"]?["private"] == .bool(true) {
            if let key = chainKey(of: id, state: state) {
                raise(chain.filter { $0 != id }, for: id, key: key, state: &state, binders: binders, commands: commands, now: now)
            } else {
                markPrivate(chain + [id], state: &state)
            }
        }
        return true
    }

    /// Whether an event's words are held: by its card, or by a stage that settles them (nothing to file, nothing to
    /// change, the same text as an event whose words are held, retracted). An event that crashed before its card was
    /// made holds nothing unless that card is found now; a stale revision's words were never carded.
    func holdsContent(_ id: String, chain: [String], state: inout State, binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        switch state.ingested[id] {
        case "ingested": adoptOrphanCard(id, chain: chain, state: &state, binders: binders, commands: commands, now: now)
        case nil, "stale_revision", "duplicate": false
        default: true
        }
    }

    /// The events of `event`'s chain, oldest first. A chain an older cursor kept under "app|ref" is used only for
    /// the events whose own app and ref are this event's.
    func chainIDs(of event: CaptureEvent, state: State) -> [String] {
        if let ids = state.chainsByKey?[event.chainKey] { return ids }
        return (state.chains?[event.legacyChainKey] ?? []).filter {
            sameSource($0, as: event, parts: [event.app, event.ref], paths: state.paths ?? [:])
        }
    }

    /// The first ingested copy of the same capture (app, ref and revision), if any. A key an older cursor kept as
    /// "app|ref|revision" still matches.
    func earlierCapture(_ event: CaptureEvent, state: State) -> String? {
        if let id = state.captures?[event.dedupeKey] { return id }
        guard let id = state.dedupe[event.legacyDedupeKey],
              sameSource(id, as: event, parts: [event.app, event.ref, event.revision], paths: state.paths ?? [:]) else { return nil }
        return id
    }

    /// Whether a key an older cursor joined with "|" for event `id` names `parts`. Joined parts that hold no "|"
    /// can come from those parts only; otherwise the stored event says, and one that cannot be read does not match,
    /// so a different note is carded rather than lost.
    func sameSource(_ id: String, as event: CaptureEvent, parts: [String], paths: [String: String]) -> Bool {
        if !parts.contains(where: { $0.contains("|") }) { return true }
        guard let source = storedEvent(id, paths: paths)?["source"] else { return false }
        let stored = ["app", "ref", "revision"].prefix(parts.count).map { source[$0]?.stringValue }
        return stored == parts.map(Optional.some)
    }

    /// The Tier 0 card of event `id` the person already acted on in a binder this Mac manages, if any.
    func actedOnCard(_ id: String, binders: [ShelfRow], deviceID: String) -> (URL, Proposal)? {
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == deviceID {
            for (p, _) in ProposalStore.list(in: row.folder) where ["applied", "rejected"].contains(p.state)
                && p.raw["provenance"]?["events"] == .array([.string(id)]) && p.raw["provenance"]?["producer"] != nil
                // One Sprava took back itself, never trusted, was not the person's to act on.
                && p.raw["rejected_reason"] != .str("its digest could not be kept") {
                return (row.folder, p)
            }
        }
        return nil
    }

    /// Which revision of a chain counts (capture-event-v0 §3.2), as text that sorts like the rule: once any event of a
    /// chain has a revision that does not start with `approx:`, the `approx:` ones (the developer importer's, 7.8) are
    /// ignored when choosing the current event, so a producer's own event always outranks an approximation; among
    /// events of one kind the highest HLC counts. Every choice of a chain's current event, baseline or what stands
    /// after a retraction goes by this rank; a raise of privacy still comes from every revision.
    static func rank(_ id: String, state: State) -> String {
        rank(clock: state.clocks?[id] ?? "", approx: (state.approx ?? []).contains(id))
    }

    static func rank(clock: String, approx: Bool) -> String { (approx ? "0:" : "1:") + clock }

    /// The event of `ids` that counts most (`rank`).
    static func counting(_ ids: [String], state: State) -> String? {
        ids.map { ($0, rank($0, state: state)) }.max { $0.1 < $1.1 }?.0
    }

    /// An event's HLC as text that sorts like the clock: wall time, counter, node, then the id breaks a tie.
    static func clockKey(_ event: CaptureEvent) -> String {
        let wall = event.raw["hlc"]?["wall_ms"]?.numberValue?.safeInteger ?? 0
        let counter = event.raw["hlc"]?["counter"]?.numberValue?.safeInteger ?? 0
        // Wall time, counter, then the node (capture-event-v0 §4.2); the id only breaks a tie of whole stamps.
        let node = event.raw["hlc"]?["node"]?.stringValue ?? ""
        return String(format: "%016lld:%08lld:", wall, counter) + node + ":" + event.id
    }

    /// Pending cards built from any event of a chain: unfiled ones, and proposals waiting in the binders this Mac
    /// manages (a binder another Mac owns is read-only here, mvp.md feature 1).
    /// Whether every card file in `dir` can be read now: a folder that is not there holds none; one that cannot be
    /// listed, or a card that cannot be read (no permission, an I/O error, another owner), means the cards were not
    /// all seen, and work that has to reach all of them is not done. A link or a special file is never a card.
    static func cardsReadable(in dir: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        for name in names where name.hasSuffix(".json") && ProposalStore.isValidID(String(name.dropLast(5))) {
            switch SafeFile.read(dir.appendingPathComponent(name)) {
            case .ok, .missing: continue
            case .refused(let why) where why == "a symbolic link" || why == "not a plain file": continue
            default: return false
            }
        }
        return true
    }

    /// Whether `pendingCards` sees every card: the Inbox's (and its digest list) and those of every binder it lists.
    /// When not, an empty answer is not "nothing waits": work that must reach every card stays owed.
    func cardsListedCompletely(binders: [ShelfRow], deviceID: String) -> Bool {
        guard Self.cardsReadable(in: unfiledDir), (try? unfiledDigests()) != nil else { return false }
        return binders.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == deviceID }
            .allSatisfy { Self.cardsReadable(in: ProposalStore.dir($0.folder)) }
    }

    func pendingCards(chain: [String], binders: [ShelfRow], deviceID: String) -> (unfiled: [Proposal], filed: [(URL, Proposal)]) {
        let ids = Set(chain)
        func fromChain(_ p: Proposal) -> Bool {
            !(p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter(ids.contains).isEmpty
        }
        let unfiled = self.unfiled().filter(fromChain)
        var filed: [(URL, Proposal)] = []
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == deviceID {
            for (p, _) in ProposalStore.list(in: row.folder) where p.state == "proposed" && fromChain(p) { filed.append((row.folder, p)) }
        }
        return (unfiled, filed)
    }
}
