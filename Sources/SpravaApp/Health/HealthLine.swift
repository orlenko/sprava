import Services

/// One row of a Health section. A macOS List matches rows by id across all its sections, so two sections that both
/// number their rows 0, 1, 2 show one section's rows in the other (a doctor finding under Backup). Each id carries
/// its section's name, and is its own type, so it cannot equal another section's row or a job's key.
struct HealthLine<Value>: Identifiable {
    struct ID: Hashable {
        let section: String
        let index: Int
    }

    let id: ID
    let value: Value

    static func rows(_ section: String, _ values: [Value]) -> [HealthLine] {
        values.enumerated().map { HealthLine(id: ID(section: section, index: $0.offset), value: $0.element) }
    }
}

extension Doctor.Finding {
    /// The finding as shown to a person: the binder's name first when there is one, then the text as a sentence.
    var sentence: String { Self.sentence(binder: binder, text: text) }

    static func sentence(binder: String?, text: String) -> String {
        let text = text.prefix(1).uppercased() + text.dropFirst()
        return binder.map { "\($0): \(text)" } ?? text
    }
}
