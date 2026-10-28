import AppKit
import SwiftUI

/// The detail pane while the app's launch starts its background part (`RuntimeKeeper.launching`): a calm screen in
/// place of pages whose reads would wait for it. Health stays reachable, for the details. The screen fades in after a
/// moment, so a launch that finds the runtime already running shows no flash of it.
struct StartingScreen<Page: View>: View {
    @ObservedObject var keeper: RuntimeKeeper
    /// False for the Health page, which shows the start itself.
    let covers: Bool
    @ViewBuilder let page: () -> Page

    /// How long the launch runs before the screen shows, and before it says a long start is expected.
    static var fadeInAfter: TimeInterval { 0.4 }
    static var longAfter: TimeInterval { 10 }

    var body: some View {
        if keeper.launching && covers {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let elapsed = context.date.timeIntervalSince(keeper.launchBegan ?? context.date)
                VStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Starting Sprava").font(.title2.weight(.semibold))
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text(Self.caption(keeper.step)).foregroundStyle(.secondary)
                    Text("After an update this can take up to a minute. Health, in the sidebar, shows the details.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(elapsed > Self.longAfter ? 1 : 0)
                }
                .multilineTextAlignment(.center)
                .opacity(elapsed > Self.fadeInAfter ? 1 : 0)
                .animation(.easeIn(duration: 0.3), value: elapsed > Self.fadeInAfter)
                .animation(.easeIn(duration: 0.3), value: elapsed > Self.longAfter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            page()
        }
    }

    /// What the start is doing, in plain words.
    static func caption(_ step: RuntimeAutostart.Step?) -> String {
        switch step {
        case .register: "Setting up Sprava's background part…"
        case .reregister: "Setting up Sprava's background part again…"
        case .kickstart: "Restarting Sprava's background part…"
        case .wait: "Waiting for Sprava's background part to answer…"
        default: "Checking on Sprava's background part…"
        }
    }
}
