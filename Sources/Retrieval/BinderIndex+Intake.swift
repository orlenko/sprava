import BinderFormat
import Foundation
import SpravaKit

extension BinderIndex {
    public static let maximumIntakeSources = 1_000

    /// Index a complete, bounded manifest from the binder's intake owner for a consented conversation.
    /// This does not discover files, grant consent, file documents, or execute code from the binder.
    /// The runtime must obtain a current manifest and refresh before supplying passages to a model.
    /// Credential/state paths are refused before the reader is called. The production reader remains
    /// HelperDocumentReader, which opens from the binder down without following links.
    public func refreshIntake(paths: [String], reader: DocumentReader) throws {
        guard paths.count <= Self.maximumIntakeSources else {
            throw Failure("too many intake sources to index in one conversation snapshot")
        }
        let sources = Set(paths)
        for path in sources {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 4_096, parts.count >= 2, parts.first == "intake",
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  Self.excluded(path) == nil,
                  !parts.contains(where: { DocumentPaths.isKeyFile(String($0)) }) else {
                throw Failure("the intake manifest contains a path that must not reach a model")
            }
        }
        // A crash or a failed refresh cannot leave a prior completion marker claiming this snapshot is whole.
        try db.execute("DELETE FROM sources WHERE kind = 'intake-manifest'")
        let indexed = try indexedRevisions()
        for path in sources.sorted() {
            let source = PassageSource.intake(path)
            try update(DocumentRecord(id: .string("intake:\(path)"), path: path), reader: reader,
                       indexed: indexed[source], source: source)
        }
        for source in indexed.keys {
            if case .intake(let path) = source, !sources.contains(path) { try remove(source) }
        }
        try db.execute("INSERT INTO sources (kind, key, revision, coverage) VALUES ('intake-manifest', '', 'complete', NULL)")
    }
}
