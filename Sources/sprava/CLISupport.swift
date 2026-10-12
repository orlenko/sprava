import CryptoKit
import Foundation
import Services
import SpravaKit

enum SymmetricKeyFromHex { static let zero = SymmetricKey(data: Data(count: 32)) }

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// This Mac's device id; one that cannot be read stops the command rather than being replaced.
func deviceID(_ support: URL) -> String {
    do { return try DeviceID.load(support: support) } catch { fail("\(error)", code: 1) }
}

func folderURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

func todayFrom(_ args: inout [String]) -> CalendarDate {
    if let i = args.firstIndex(of: "--today") {
        guard i + 1 < args.count, let date = CalendarDate.strict(args[i + 1]) else { fail("--today needs YYYY-MM-DD") }
        args.removeSubrange(i...(i + 1))
        return date
    }
    return CalendarDate.today()
}

func ago(_ date: Date?) -> String {
    guard let date else { return "-" }
    let seconds = max(0, Date().timeIntervalSince(date))
    switch seconds {
    case ..<3600: return "\(Int(seconds / 60))m ago"
    case ..<86_400: return "\(Int(seconds / 3600))h ago"
    default: return "\(Int(seconds / 86_400))d ago"
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

final class RunBox<T>: @unchecked Sendable { var value: T? }

func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = RunBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}
