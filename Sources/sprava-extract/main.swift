import Foundation
import SpravaCore

// sprava-extract: the extraction helper of architecture 2.1. It reads one file's bytes on standard input and
// writes the extracted text and facts as JSON on standard output. It opens no file and no network connection;
// in the app bundle it is signed with the App Sandbox and nothing else, so a parser exploit gains nothing.
// Usage: sprava-extract <file name>   (the name is used only to notice a type that does not match the bytes)

let name = CommandLine.arguments.dropFirst().first ?? "file"
let limit = 200 * 1024 * 1024
var data = Data()
while true {
    let chunk = FileHandle.standardInput.readData(ofLength: 1 << 20)
    if chunk.isEmpty { break }
    data.append(chunk)
    if data.count > limit { break }
}
let r = Extractor.extract(data, name: name)
var o = JSONObject()
o.set("kind", .string(r.kind))
o.set("text", .string(r.text))
o.set("text_from", .string(r.textFrom))
if let pages = r.pages { o.set("pages", .int(pages)) }
if let problem = r.problem { o.set("problem", .string(problem)) }
if r.mismatch { o.set("mismatch", .bool(true)) }
if let e = r.email {
    var em = JSONObject()
    for (k, v) in [("subject", e.subject), ("from", e.from), ("to", e.to), ("date", e.date), ("message_id", e.messageID)] {
        if let v { em.set(k, .string(v)) }
    }
    em.set("attachments", .array(e.attachments.map { .obj([("name", .string($0.name)), ("data", .string($0.data.base64EncodedString()))]) }))
    o.set("email", .object(em))
}
FileHandle.standardOutput.write(Data(JSONWriter.compact(.object(o)).utf8))
