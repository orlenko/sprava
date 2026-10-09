import Foundation
import FoundationModels
import Services
import UserNotifications

/// Notifications under the app's identity. A helper inside the bundle has the app's bundle as its main bundle;
/// whether macOS delivers its notifications is spike h (architecture 3.7). Outside a bundle (a `swift build`
/// binary) there is no identity, and posting is skipped and reported.
enum Notifier {
    static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func authorized() -> Bool? {
        guard hasBundle else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = false
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            result = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 5) == .success ? result : false
    }

    static func post(title: String, body: String, id: String) -> Bool {
        guard hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        UNUserNotificationCenter.current().add(request) { error in
            ok = error == nil
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 5) == .success && ok
    }
}

/// The clerk's line on the Health page: whether the on-device model is available, and its context size.
enum ModelStatus {
    static func read() -> Heartbeat.Model {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return Heartbeat.Model(availability: "available", context_size: model.contextSize, variant: nil,
                                   last_success: nil, errors_24h: nil)
        case .unavailable(let reason):
            let name: String
            switch reason {
            case .deviceNotEligible: name = "deviceNotEligible"
            case .appleIntelligenceNotEnabled: name = "appleIntelligenceNotEnabled"
            case .modelNotReady: name = "modelNotReady"
            @unknown default: name = "modelNotReady"
            }
            return Heartbeat.Model(availability: name, context_size: nil, variant: nil, last_success: nil, errors_24h: nil)
        }
    }
}

/// Waits for async work from a job's thread. Jobs run on a global queue, never on the state queue.
final class BlockingBox<T>: @unchecked Sendable { var value: T? }

func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = BlockingBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}
