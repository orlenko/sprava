@testable import Backup
import Testing

@Suite struct BackupKeyGenerationTests {
    @Test func generatedKeysAreRandomAndWellFormed() {
        let keys = (0..<64).map { _ in BackupKey.generate() }
        #expect(Set(keys).count == keys.count)
        #expect(!keys.contains(BackupKey.format([UInt8](repeating: 0, count: 30))))
        for key in keys {
            #expect(key.wholeMatch(of: /[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){5}/) != nil)
        }
    }

    @Test func zeroBytesWouldMakeTheAllAKey() {
        #expect(BackupKey.format([UInt8](repeating: 0, count: 30)) == "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA")
    }

    @Test func keysAreTypableAndCompareLoosely() {
        let key = BackupKey.generate()
        #expect(key.count == 35 && key.split(separator: "-").count == 6)
        #expect(BackupKey.normalize(key.lowercased().replacingOccurrences(of: "-", with: " ")) == BackupKey.normalize(key))
    }
}
