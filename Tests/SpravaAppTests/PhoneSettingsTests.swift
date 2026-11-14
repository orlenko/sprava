import Foundation
import SpravaKit
import Testing
@testable import SpravaApp

/// Invented relay, phone and codes only.
@MainActor @Suite struct PhoneSettingsTests {
    private let phoneID = "BwcHBwcHBwcHBwcHBwcHBw"
    private let link = "https://phone.example/#pair=v0.invented"

    /// A model whose polls run only when the test steps them.
    private func model(_ runtime: StandInRuntime, now: Date = Date(timeIntervalSince1970: 0)) -> PhoneSettings {
        PhoneSettings(client: runtime.client, wait: { _ in try await Task.sleep(for: .seconds(3600)) }, now: { now })
    }
    private func answer(_ fields: [(String, JSONValue)]) -> String {
        JSONWriter.compact(.obj([("ok", .bool(true))] + fields))
    }
    private func commands(_ runtime: StandInRuntime) -> [String?] { runtime.sent.map { $0["command"]?.stringValue } }

    @Test func connectingSendsTheSetupClaimsAndForgetsTheCode() async {
        let runtime = StandInRuntime()
        runtime.answers["companion_configure"] = { [self] _ in answer([("state", .str("pending"))]) }
        runtime.answers["companion_claim"] = { [self] _ in answer([("state", .str("claimed"))]) }
        runtime.answers["companion_devices"] = { [self] _ in answer([("devices", .array([]))]) }
        let phone = model(runtime)
        phone.relayAddress = " https://relay.example/ "; phone.setupCode = "invented-setup-code"
        phone.webAddress = "https://phone.example"
        await phone.connect()
        #expect(commands(runtime) == ["companion_configure", "companion_claim", "companion_devices"])
        let sent = runtime.sent[0]
        #expect(sent["relay_origin"] == .str("https://relay.example") && sent["setup_code"] == .str("invented-setup-code"))
        #expect(sent["web_origin"] == .str("https://phone.example"))
        #expect(phone.connected && phone.setupCode.isEmpty && phone.message == nil && !phone.busy)
    }

    @Test func connectNeedsTheWebAddressAndKeepsTheCodeWhenRefused() async {
        let runtime = StandInRuntime()
        runtime.answers["companion_configure"] = { _ in
            #"{"ok":false,"error":"Check the relay address, setup code and web app address."}"#
        }
        let phone = model(runtime)
        phone.relayAddress = "https://relay.example"; phone.setupCode = "invented-setup-code"
        await phone.connect()
        #expect(runtime.sent.isEmpty)
        phone.webAddress = "https://phone.example"
        await phone.connect()
        #expect(phone.message == "Check the relay address, setup code and web app address.")
        #expect(phone.setupCode == "invented-setup-code" && !phone.connected)
    }

    @Test func loadingShowsTheStateAndPairedPhones() async {
        let runtime = StandInRuntime()
        runtime.answers["companion_status"] = { [self] _ in answer([("state", .str("claimed"))]) }
        runtime.answers["companion_devices"] = { [self] _ in answer([("devices", .array([
            .obj([("device_id", .str(phoneID)), ("label", .str("Invented phone")), ("paired_at", .str("2026-11-13T10:00:00Z")),
                  ("confirmation", .str("acknowledged"))]),
        ]))]) }
        let phone = model(runtime)
        await phone.load()
        #expect(phone.stateLine == "Connected to the relay.")
        #expect(phone.devices == [.init(id: phoneID, label: "Invented phone", pairedAt: "2026-11-13T10:00:00Z",
                                        confirmed: true, awaiting: false)])
        #expect(!phone.isDelivering(phoneID))
        let unconfigured = StandInRuntime()
        unconfigured.answers["companion_status"] = { [self] _ in answer([("state", .str("not-configured"))]) }
        let fresh = model(unconfigured)
        await fresh.load()
        #expect(commands(unconfigured) == ["companion_status"] && !fresh.configured)
    }

    @Test func pairingShowsTheLinkThenTheCodeAndConfirmsOnlyThatCode() async throws {
        let runtime = StandInRuntime()
        runtime.answers["companion_status"] = { [self] _ in answer([("state", .str("claimed"))]) }
        runtime.answers["companion_devices"] = { [self] _ in answer([("devices", .array([]))]) }
        runtime.answers["companion_pairing_start"] = { [self] _ in
            answer([("state", .str("waiting")), ("device_id", .str(phoneID)), ("link", .str(link)),
                    ("expires_at", .str("1970-01-01T00:10:00Z"))])
        }
        var polls: [String] = [
            answer([("state", .str("waiting")), ("retry_at", .str("1970-01-01T00:00:02Z"))]),
            answer([("state", .str("confirm")), ("label", .str("Invented phone")), ("confirmation", .str("123456"))]),
            answer([("state", .str("delivering")), ("retry_at", .str("1970-01-01T00:00:04Z"))]),
            answer([("state", .str("paired"))]),
        ]
        runtime.answers["companion_pairing_poll"] = { _ in polls.removeFirst() }
        runtime.answers["companion_pairing_confirm"] = { [self] _ in answer([("state", .str("delivering"))]) }
        let phone = model(runtime)
        await phone.load()
        await phone.startPairing()
        #expect(phone.pairing == .init(deviceID: phoneID, link: link, stage: .waiting))
        #expect(PhoneSettings.qrCode(link) != nil)
        await phone.poll()
        #expect(phone.pairing?.stage == .waiting)
        await phone.poll()
        #expect(phone.pairing?.stage == .confirm(label: "Invented phone", code: "123456"))
        await phone.confirmPairing()
        let confirm = try #require(runtime.sent.first { $0["command"] == .str("companion_pairing_confirm") })
        #expect(confirm["device_id"] == .str(phoneID) && confirm["confirmation"] == .str("123456"))
        #expect(phone.pairing?.stage == .delivering && phone.isDelivering(phoneID))
        #expect(await phone.deliveryStep(phoneID) == 4)
        #expect(await phone.deliveryStep(phoneID) == nil)
        #expect(phone.pairing?.stage == .paired && polls.isEmpty)
        #expect(commands(runtime).last == "companion_devices")
        phone.closePairing()
        #expect(phone.pairing == nil)
    }

    /// Regression: closing the panel, or quitting, after "The Codes Match" must not drop the approved delivery.
    @Test func anApprovedPairingKeepsDeliveringAfterThePanelClosesAndAfterARelaunch() async {
        let runtime = StandInRuntime()
        runtime.answers["companion_status"] = { [self] _ in answer([("state", .str("claimed"))]) }
        runtime.answers["companion_devices"] = { [self] _ in answer([("devices", .array([
            .obj([("device_id", .str(phoneID)), ("label", .str("Invented phone")), ("paired_at", .str("2026-11-13T10:00:00Z")),
                  ("confirmation", .str("awaiting"))]),
        ]))]) }
        runtime.answers["companion_pairing_start"] = { [self] _ in answer([("device_id", .str(phoneID)), ("link", .str(link))]) }
        runtime.answers["companion_pairing_poll"] = { [self] _ in
            answer([("state", .str("confirm")), ("label", .str("Invented phone")), ("confirmation", .str("123456"))])
        }
        runtime.answers["companion_pairing_confirm"] = { [self] _ in answer([("state", .str("delivering"))]) }
        let phone = model(runtime)
        await phone.load()
        await phone.startPairing()
        await phone.poll()
        await phone.confirmPairing()
        phone.closePairing()
        #expect(phone.pairing == nil && phone.isDelivering(phoneID))
        let relaunched = model(runtime)
        await relaunched.load()
        #expect(relaunched.devices.first?.awaiting == true && relaunched.isDelivering(phoneID))
    }

    @Test func aBusyOrSlowPollKeepsThePairingAndARefusalStopsIt() async {
        let runtime = StandInRuntime()
        runtime.answers["companion_status"] = { [self] _ in answer([("state", .str("claimed"))]) }
        runtime.answers["companion_devices"] = { [self] _ in answer([("devices", .array([]))]) }
        runtime.answers["companion_pairing_start"] = { [self] _ in
            answer([("device_id", .str(phoneID)), ("link", .str(link))])
        }
        var reply = #"{"ok":false,"error":"Another Phone action is running. Try again when it finishes."}"#
        runtime.answers["companion_pairing_poll"] = { _ in reply }
        let phone = model(runtime)
        await phone.load()
        await phone.startPairing()
        await phone.poll()
        #expect(phone.pairing?.stage == .waiting && phone.message == nil)
        reply = #"{"ok":false,"error":"This pairing expired. Start pairing again."}"#
        await phone.poll()
        #expect(phone.message == "This pairing expired. Start pairing again.")
    }

    /// Regression: a phone awaiting delivery on a later device page is found and resumed too.
    @Test func loadingReadsEveryDevicePageAndResumesADeliveryOnALaterOne() async {
        let runtime = StandInRuntime()
        let later = "CAgICAgICAgICAgICAgICA"
        runtime.answers["companion_status"] = { [self] _ in answer([("state", .str("claimed"))]) }
        runtime.answers["companion_devices"] = { [self] request in
            if request["after"] == nil {
                return answer([("devices", .array([.obj([("device_id", .str(phoneID)), ("label", .str("Invented phone")),
                    ("paired_at", .str("2026-11-13T10:00:00Z")), ("confirmation", .str("acknowledged"))])])), ("next", .str(phoneID))])
            }
            #expect(request["after"] == .str(phoneID))
            return answer([("devices", .array([.obj([("device_id", .str(later)), ("label", .str("Invented tablet")),
                ("paired_at", .str("2026-11-13T10:00:00Z")), ("confirmation", .str("awaiting"))])]))])
        }
        let phone = model(runtime)
        await phone.load()
        #expect(phone.devices.map(\.id) == [phoneID, later])
        #expect(phone.isDelivering(later) && !phone.isDelivering(phoneID))
    }

    @Test func pairingWaitsAtTheRuntimesTimeWithinBounds() {
        let phone = model(StandInRuntime(), now: Date(timeIntervalSince1970: 100))
        #expect(phone.delay(until: "1970-01-01T00:01:44Z") == 4)
        #expect(phone.delay(until: "1970-01-01T00:00:00Z") == 1)
        #expect(phone.delay(until: "1970-01-01T01:00:00Z") == 10)
        #expect(phone.delay(until: nil) == 2 && phone.delay(until: "not a time") == 2)
    }

    @Test func pairingIsOfferedOnlyOnceTheRelayIsClaimed() async {
        let runtime = StandInRuntime()
        runtime.answers["companion_status"] = { [self] _ in answer([("state", .str("pending"))]) }
        runtime.answers["companion_devices"] = { [self] _ in answer([("devices", .array([]))]) }
        let phone = model(runtime)
        await phone.load()
        await phone.startPairing()
        #expect(phone.pairing == nil && !commands(runtime).contains("companion_pairing_start"))
        #expect(phone.stateLine.contains("Claim"))
    }
}
