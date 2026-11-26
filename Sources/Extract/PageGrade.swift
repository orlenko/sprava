extension Extractor.Page {
    public enum Grade: String, Sendable { case good, poor, unreadable }

    public var grade: Grade {
        let count = text.unicodeScalars.lazy.filter { !$0.properties.isWhitespace }.count
        guard count > 0 else { return .unreadable }
        if incompleteCoverage || (method == .ocr && (confidence ?? 0) < 0.70) { return .poor }
        if let area, Double(count) < area / 12_000 { return .poor }
        return .good
    }
}
