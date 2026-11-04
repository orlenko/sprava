import SpravaKit
import SwiftUI

/// A binder's working page and its settings, both always mounted: going between them cancels no reply and loses no draft, on
/// either side, such as an email setup half filled in.
struct BinderPageLayers<Working: View, Settings: View>: View {
    let settingsShown: Bool
    @ViewBuilder let working: Working
    @ViewBuilder let settings: Settings

    var body: some View {
        ZStack {
            layer(working, shown: !settingsShown)
            layer(settings, shown: settingsShown)
        }
    }

    private func layer(_ view: some View, shown: Bool) -> some View {
        view.opacity(shown ? 1 : 0).disabled(!shown).allowsHitTesting(shown).accessibilityHidden(!shown)
    }
}

/// What is set up once and then left alone, apart from the page a binder is worked on: its connection to Claude, its email
/// intake, and the rows about the binder itself.
struct BinderSettingsPage: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let today: CalendarDate
    let writable: Bool
    let conversation: ClaudeBinderConversation?
    let reload: () -> Void

    var body: some View {
        List {
            if let conversation {
                Section("Assistant") { ConversationSettings(model: conversation) }
            }
            if writable { EmailIntakeSection(folder: folder, expanded: true) }
            Section("About this binder") {
                VStack(alignment: .leading, spacing: 10) {
                    RoutingRows(actions: actions, folder: folder)
                    Divider()
                    KeepingRows(actions: actions, folder: folder, today: today, reload: reload)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// On the working page, only when set-up email intake has stopped and needs the person: the one thing about it that cannot
/// wait for a visit to the settings.
struct EmailIntakeAttention: View {
    let folder: URL
    let open: () -> Void
    @StateObject private var model: EmailIntakeModel

    init(folder: URL, model: @autoclosure @escaping () -> EmailIntakeModel = EmailIntakeModel(), open: @escaping () -> Void) {
        self.folder = folder
        self.open = open
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        // A stack, not a Group: an empty Group draws nothing, so its task, which finds out whether to show, would never run.
        VStack(alignment: .leading, spacing: 0) {
            if model.status.enabled && model.status.needsPassword {
                HStack {
                    Text("Email intake needs its password.").foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings", action: open)
                }
            }
        }
        .task(id: folder) {
            await model.show(folder)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15)); if Task.isCancelled { break }
                await model.show(folder)
            }
        }
    }
}
