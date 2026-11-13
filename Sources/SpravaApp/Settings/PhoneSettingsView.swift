import SwiftUI

/// Settings › Phone. Connect, pair and list; the model does the work (PhoneSettings).
struct PhoneSettingsView: View {
    @ObservedObject var model: PhoneSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                relay
                Divider()
                if let pairing = model.pairing { pairingPanel(pairing) } else { phones }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load() }
    }

    private var relay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relay").font(.headline)
            Text(model.stateLine).fixedSize(horizontal: false, vertical: true)
            if !model.configured {
                Form {
                    TextField("Relay address", text: $model.relayAddress, prompt: Text("https://relay.example.org"))
                    SecureField("Setup code", text: $model.setupCode)
                    TextField("Web app address", text: $model.webAddress, prompt: Text("https://phone.example.org"))
                }
                Button("Connect") { Task { await model.connect() } }
                    .disabled(model.busy || model.relayAddress.isEmpty || model.setupCode.isEmpty || model.webAddress.isEmpty)
                Text("The relay's address and setup code come from where you run the relay. The web app address is where your phone opens Sprava.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.state == "pending" || model.state == "checking-refusal" {
                Button("Claim") { Task { await model.claim() } }.disabled(model.busy)
            }
        }
    }

    private var phones: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phones").font(.headline)
            if model.devices.isEmpty {
                Text(model.connected ? "No phone is paired yet." : "Connect to a relay to pair a phone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                HStack {
                    Text(device.label)
                    Spacer()
                    Text(device.confirmed ? "Paired" : device.awaiting ? "Sending its keys…" : "The phone did not confirm")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.connected {
                Button("Pair a Phone…") { Task { await model.startPairing() } }.disabled(model.busy)
            }
            Text("A phone cannot be removed from here yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pairingPanel(_ pairing: PhoneSettings.Pairing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a phone").font(.headline)
            switch pairing.stage {
            case .waiting:
                Text("Scan this code with your phone's camera and open the link. Keep this window open.")
                    .fixedSize(horizontal: false, vertical: true)
                if let image = PhoneSettings.qrCode(pairing.link) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .accessibilityLabel("Pairing code")
                }
                Button("Copy Link") { _ = ProtectedClipboard.copy(pairing.link) }
                    .help("For a browser on this Mac. The copy clears itself after a minute.")
            case .confirm(let label, let code):
                Text("Check that “\(label)” shows the same code:").fixedSize(horizontal: false, vertical: true)
                Text(code).font(.system(size: 34, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("The Codes Match") { Task { await model.confirmPairing() } }
                        .keyboardShortcut(.defaultAction).disabled(model.busy)
                    Button("They Differ") { model.closePairing() }
                }
                Text("If the codes differ, do not pair: close this and start again.")
                    .font(.caption).foregroundStyle(.secondary)
            case .delivering:
                Text("Sending the keys to the phone…")
            case .paired:
                Text("The phone is paired.")
            case .notConfirmed:
                Text("The phone did not confirm in time. Start pairing again if it does not show your to-dos.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .confirm = pairing.stage {} else {
                Button(pairing.stage == .paired ? "Done" : "Close") { model.closePairing() }
            }
        }
    }
}
