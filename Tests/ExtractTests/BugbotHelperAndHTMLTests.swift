@testable import Extract
import Foundation
import Testing

/// Regressions from Codex Bugbot's fourth pass on the Shelf and Extract layer (PR #11): a helper that ignores
/// SIGTERM never wedges the caller, and every valid closing form of a script, style, noscript or template element
/// ends its stripping. Invented data only.
@Suite(.serialized) struct BugbotHelperAndHTMLTests {
    /// A stand-in helper: a shell script in its own new folder.
    func stub(_ script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-helper06-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sprava-extract")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    // MARK: - A helper that ignores SIGTERM is killed, and the caller goes on

    @Test func aHelperIgnoringTermIsKilledWithinItsBound() throws {
        // It ignores SIGTERM, and leaves a child holding its output open after it is gone.
        let helper = try stub("trap '' TERM\nsleep 20 &\nsleep 20")
        let start = Date()
        let error = #expect(throws: ExtractHelper.Failure.self) {
            try ExtractHelper.launch(helper, data: Data("x".utf8), name: "invented.txt", timeout: 1, grace: 0.5)
        }
        #expect(error?.message.contains("longer than 1 seconds") == true, "\(String(describing: error))")
        #expect(Date().timeIntervalSince(start) < 8, "\(Date().timeIntervalSince(start)) seconds")
    }

    @Test func aHelperThatAnswersIsReadAndReturnsAtOnce() throws {
        let helper = try stub(#"cat > /dev/null; printf '{"kind":"text","text":"Invented note","text_from":"parsed"}'"#)
        let start = Date()
        let r = try ExtractHelper.launch(helper, data: Data("Invented note".utf8), name: "note.txt", timeout: 30, grace: 5)
        #expect(r.text == "Invented note")
        #expect(Date().timeIntervalSince(start) < 3, "\(Date().timeIntervalSince(start)) seconds")
    }

    // MARK: - Script, style, noscript and template content never reaches the reading

    @Test func everyClosingFormEndsAStrippedElement() {
        let pages = [
            "<p>Invented levy</p><script>INVENTED-SCRIPT</script ><p>due Friday</p>",
            "<p>Invented levy</p><SCRIPT type=\"text/javascript\">INVENTED-SCRIPT</SCRIPT\t\n><p>due Friday</p>",
            "<p>Invented levy</p><script>INVENTED-SCRIPT</script foo=\"bar\"><p>due Friday</p>",
            "<p>Invented levy</p><Style media=\"all\">INVENTED-SCRIPT { }</sTyLe ><p>due Friday</p>",
            "<p>Invented levy</p><noscript>INVENTED-SCRIPT</noscript><p>due Friday</p>",
            "<p>Invented levy</p><template id=\"t\">INVENTED-SCRIPT</template /><p>due Friday</p>",
        ]
        for html in pages {
            let text = Extractor.htmlText(html)
            #expect(!text.contains("INVENTED-SCRIPT"), "\(html) -> \(text)")
            #expect(text.contains("Invented levy") && text.contains("due Friday"), "\(html) -> \(text)")
        }
        // A script never closed runs to the end of the page, as a browser reads it.
        #expect(!Extractor.htmlText("<p>Invented levy</p><script>INVENTED-SCRIPT").contains("INVENTED-SCRIPT"))
        // An element whose name only starts like one of them is ordinary markup.
        #expect(Extractor.htmlText("<scripture>Invented verse</scripture>").contains("Invented verse"))
    }
}
