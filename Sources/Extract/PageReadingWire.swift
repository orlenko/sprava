import SpravaKit

extension Extractor.Page {
    public var json: JSONValue {
        var fields = JSONObject([("text", .str(text)), ("method", .str(method.rawValue))])
        if let confidence { fields.set("confidence", .number(JSONNumber(text: String(confidence)))) }
        if let area { fields.set("area", .number(JSONNumber(text: String(area)))) }
        return .object(fields)
    }

    init?(json: JSONValue) {
        guard let text = json["text"]?.stringValue, let raw = json["method"]?.stringValue,
              let method = Method(rawValue: raw) else { return nil }
        let confidence = json["confidence"]?.numberValue?.doubleValue
        let area = json["area"]?.numberValue?.doubleValue
        if json["confidence"] != nil {
            guard method == .ocr, let confidence, (0...1).contains(confidence) else { return nil }
        }
        if json["area"] != nil {
            guard let area, area.isFinite, area > 0 else { return nil }
        }
        self.init(text: text, method: method, confidence: confidence, area: area)
    }
}
