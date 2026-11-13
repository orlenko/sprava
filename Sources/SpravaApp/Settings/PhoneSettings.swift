import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SpravaKit
import SwiftUI

/// Settings › Phone (companion.md §§4, 13): connect this Mac to a relay, pair a phone with a QR code and the
/// six-digit check, and list paired phones. Every change goes to the runtime. The setup code is cleared once sent;
/// the pairing link (a secret) lives only in the open pairing and is never logged.
@MainActor
final class PhoneSettings: ObservableObject, RuntimePage {
    struct Device: Identifiable, Equatable {
        let id: String
        let label: String
        let pairedAt: String
        let confirmed: Bool
    }
    struct Pairing: Equatable {
        enum Stage: Equatable { case waiting, confirm(label: String, code: String), delivering, paired, notConfirmed }
        let deviceID: String
        let link: String
        var stage: Stage
    }

    @Published var relayAddress = ""
    @Published var setupCode = ""
    @Published var webAddress = ""
    /// The runtime's claim state word (`companion_status`); nil until read.
    @Published private(set) var state: String?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var pairing: Pairing?
    @Published private(set) var busy = false
    @Published var message: String? { didSet { readFoundNoRuntime = false } }
    var readFoundNoRuntime = false
    let client: RuntimeClient
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private let now: () -> Date
    private var polling: Task<Void, Never>?

    /// Each Phone action makes at most three relay calls of at most 30 seconds (§6).
    static let actionTimeout: TimeInterval = 100
    /// The runtime's fixed sentence for a Phone action that met another one running; a poll then just waits.
    static let busyAnswer = "Another Phone action is running."

    init(client: RuntimeClient = RuntimeClient(),
         wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         now: @escaping () -> Date = Date.init) {
        self.client = client; self.wait = wait; self.now = now
        client.clearsNotRunning(self)
    }

    var connected: Bool { state == "claimed" }
    var configured: Bool { state != nil && state != "not-configured" }

    /// What the relay connection is, in plain words.
    var stateLine: String {
        switch state {
        case nil: "Checking…"
        case "not-configured": "Not connected. Enter your relay's address and setup code."
        case "pending": "The relay is set up but not claimed yet. Claim it to finish connecting."
        case "claimed": "Connected to the relay."
        case "checking-refusal": "The relay did not accept this Mac. Claim it again to check."
        case "needs-reset": "Another setup claimed this relay. It needs a new instance and setup code, and Sprava cannot reset phone access yet."
        case "instance-changed": "The relay was started over. Phone access must be set up again, and Sprava cannot reset it yet."
        default: "Phone access is in a state this version does not know."
        }
    }

    func load() async {
        do {
            state = try await client.global("companion_status", timeout: 5)["state"]?.stringValue
            if configured { try await readDevices() } else { devices = [] }
        } catch { readFailed(Self.plain(error, "Phone access could not be read. Try again in a moment."), error) }
    }

    private func readDevices() async throws {
        let reply = try await client.global("companion_devices", timeout: 5)
        devices = (reply["devices"]?.arrayValue ?? []).compactMap { d in
            guard let id = d["device_id"]?.stringValue, let label = d["label"]?.stringValue else { return nil }
            return Device(id: id, label: label, pairedAt: d["paired_at"]?.stringValue ?? "",
                          confirmed: d["confirmation"]?.stringValue == "acknowledged")
        }
    }

    /// Sends the relay's address and setup code, then claims the relay. The code is cleared once the runtime has it.
    func connect() async {
        let relay = Self.origin(relayAddress), web = Self.origin(webAddress)
        let code = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        // The web app address is required until a shared build exists (plan-2026-11 §6): pairing needs it.
        guard !busy, !relay.isEmpty, !code.isEmpty, !web.isEmpty else { return }
        busy = true; defer { busy = false }
        let fields: [(String, JSONValue)] = [("relay_origin", .str(relay)), ("setup_code", .str(code)), ("web_origin", .str(web))]
        do {
            state = try await client.global("companion_configure", fields, timeout: Self.actionTimeout)["state"]?.stringValue
            setupCode = ""
            message = nil
            if state == "pending" { try await claimNow() }
        } catch { message = Self.plain(error, "The relay could not be connected. Check its address and setup code.") }
    }

    func claim() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await claimNow(); message = nil }
        catch { message = Self.plain(error, "The relay could not be claimed. Try again in a moment.") }
    }

    private func claimNow() async throws {
        state = try await client.global("companion_claim", timeout: Self.actionTimeout)["state"]?.stringValue
        if configured { try await readDevices() }
    }

    func startPairing() async {
        guard !busy, connected, pairing == nil else { return }
        busy = true; defer { busy = false }
        do {
            let reply = try await client.global("companion_pairing_start", timeout: Self.actionTimeout)
            guard let id = reply["device_id"]?.stringValue, let link = reply["link"]?.stringValue else {
                message = "Pairing could not start. Try again in a moment."; return
            }
            message = nil
            pairing = Pairing(deviceID: id, link: link, stage: .waiting)
            schedulePoll(after: 2)
        } catch { message = Self.plain(error, "Pairing could not start. Try again in a moment.") }
    }

    /// Called only after the person has compared the code on both screens.
    func confirmPairing() async {
        guard !busy, let current = pairing, case .confirm(_, let code) = current.stage else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await client.global("companion_pairing_confirm",
                                        [("device_id", .str(current.deviceID)), ("confirmation", .str(code))],
                                        timeout: Self.actionTimeout)
            guard pairing?.deviceID == current.deviceID else { return }
            pairing?.stage = .delivering
            schedulePoll(after: 0)
        } catch { message = Self.plain(error, "The phone could not be paired. Start pairing again.") }
    }

    /// Stops showing the pairing. The relay forgets an unfinished pairing when it expires.
    func closePairing() {
        polling?.cancel(); polling = nil
        pairing = nil
    }

    private func schedulePoll(after delay: TimeInterval) {
        polling?.cancel()
        polling = Task { [weak self, wait] in
            do { try await wait(delay) } catch { return }
            await self?.poll()
        }
    }

    /// One poll. Waiting and delivery schedule the next at the runtime's time; the code waits for the person.
    func poll() async {
        guard let current = pairing, !Task.isCancelled else { return }
        do {
            let reply = try await client.global("companion_pairing_poll", [("device_id", .str(current.deviceID))],
                                                timeout: Self.actionTimeout)
            guard pairing?.deviceID == current.deviceID, !Task.isCancelled else { return }
            let next = delay(until: reply["retry_at"]?.stringValue)
            switch reply["state"]?.stringValue {
            case "waiting": pairing?.stage = .waiting; schedulePoll(after: next)
            case "delivering": pairing?.stage = .delivering; schedulePoll(after: next)
            case "confirm":
                pairing?.stage = .confirm(label: reply["label"]?.stringValue ?? "",
                                          code: reply["confirmation"]?.stringValue ?? "")
            case "paired": pairing?.stage = .paired; try await readDevices()
            case "not-confirmed": pairing?.stage = .notConfirmed; try await readDevices()
            default: message = "Pairing stopped. Start pairing again."
            }
        } catch let failure as RuntimeClient.Failure
                    where failure.kind == .timedOut || failure.message.hasPrefix(Self.busyAnswer) {
            // Nothing was decided: try the same pairing again shortly.
            if pairing?.deviceID == current.deviceID { schedulePoll(after: 5) }
        } catch {
            guard pairing?.deviceID == current.deviceID else { return }
            message = Self.plain(error, "Pairing stopped. Start pairing again.")
        }
    }

    /// Seconds until the runtime's next-at time, between 1 and 10; 2 when it gave none.
    func delay(until text: String?) -> TimeInterval {
        guard let text, let date = try? Date(text, strategy: .iso8601) else { return 2 }
        return min(10, max(1, date.timeIntervalSince(now())))
    }

    /// An address as typed, without surrounding spaces or one closing slash.
    static func origin(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// Phone refusals are the runtime's fixed sentences, written for this page; other failures get the fallback.
    static func plain(_ error: Error, _ fallback: String) -> String {
        guard let failure = error as? RuntimeClient.Failure else { return fallback }
        switch failure.kind {
        case .notRunning: return failure.message
        case .timedOut: return "Sprava did not answer in time. Check this page again before retrying."
        case .refused: return failure.message.isEmpty || failure.message == "refused" ? fallback : failure.message
        }
    }

    /// The pairing link as a QR code, drawn sharp at any size.
    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
