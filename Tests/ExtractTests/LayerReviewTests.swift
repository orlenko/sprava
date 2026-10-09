import Foundation
import ImageIO
@testable import Extract
import Testing

/// Regressions from the review of the Shelf and Extract layer (the helper's sandbox, mail sniffing, quoted MIME
/// parameters, readings cut by a limit, multi-page TIFFs, unreadable office parts, Word tables). Invented data only.
@Suite(.serialized) struct LayerReviewTests {
    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-layer06-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func readMessage(_ eml: String, name: String = "message.eml") throws -> IntakeReading {
        let url = temp("eml").appendingPathComponent(name)
        try Data(eml.utf8).write(to: url)
        return IntakeReading.read(url, channel: "email", reader: .inProcess)
    }

    // MARK: - 1. A helper without its sandbox never receives a document

    @Test func aHelperWithoutTheSandboxIsRefusedBeforeAnyByteIsSent() throws {
        let dir = temp("helper")
        let received = dir.appendingPathComponent("received")
        let helper = dir.appendingPathComponent("sprava-extract")
        try Data("#!/bin/sh\n/bin/cat > '\(received.path)'\necho '{\"kind\":\"text\",\"text\":\"read\"}'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(!ExtractHelper.isSandboxed(helper))
        #expect(throws: ExtractHelper.Failure.self) {
            try ExtractHelper.run(Data("An invented note: INVENTED-SECRET-8101".utf8), name: "note.txt", reader: .helper(helper))
        }
        #expect(!FileManager.default.fileExists(atPath: received.path))
        let file = dir.appendingPathComponent("note.txt")
        try Data("An invented note.".utf8).write(to: file)
        #expect(IntakeReading.read(file, channel: "other", reader: .helper(helper)).held?.contains("sandbox") == true)
        #expect(!FileManager.default.fileExists(atPath: received.path))
    }

    @Test func onlyASignatureWithTheSandboxAloneCounts() throws {
        let dir = temp("signed")
        func signed(_ entitlements: String) throws -> URL {
            let plist = dir.appendingPathComponent("\(UUID().uuidString).entitlements")
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\(entitlements)</dict></plist>
            """.utf8).write(to: plist)
            let tool = dir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: tool.path)
            #expect(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", plist.path, tool.path]) == 0)
            return tool
        }
        #expect(ExtractHelper.isSandboxed(try signed("<key>com.apple.security.app-sandbox</key><true/>")))
        #expect(!ExtractHelper.isSandboxed(try signed("<key>com.apple.security.app-sandbox</key><false/>")))
        #expect(!ExtractHelper.isSandboxed(try signed("<key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/>")))
        #expect(!ExtractHelper.isSandboxed(URL(fileURLWithPath: "/bin/cat")))
    }

    // MARK: - 2. A message without a subject, or opening with a signature header, is still a message

    @Test func messagesAreRecognizedByTheirHeaderBlock() throws {
        let parts = """
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=utf-8

        Invented notice: the water will be off on November 4, 2026.
        --XYZ
        Content-Type: text/plain; name="credentials.txt"
        Content-Disposition: attachment; filename="credentials.txt"

        user: invented password: INVENTED-SECRET-8201
        --XYZ--
        """
        for head in ["From: manager@example.com\nTo: person@example.com\nDate: Tue, 6 Oct 2026 09:00:00 -0400\nMIME-Version: 1.0\n",
                     "DKIM-Signature: v=1; a=rsa-sha256; d=example.com;\n s=invented; b=AAAA\nFrom: manager@example.com\nSubject: Invented water notice\n"] {
            let eml = head + parts
            let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
            #expect(extracted.kind == "email" && !extracted.mismatch)
            #expect(extracted.text.contains("water will be off") && !extracted.text.contains("INVENTED-SECRET"))
            let r = try readMessage(eml)
            #expect(r.held == nil && !r.text.contains("INVENTED-SECRET"))
            #expect(r.notes.contains { $0.contains("credentials.txt") && $0.contains("key or credential file") }, "\(r.notes)")
        }
        // Text that carries MIME parts but does not open as a message is held, never read as plain text.
        let r = try readMessage("Forwarded below.\n\n" + parts, name: "forwarded.txt")
        #expect(r.held != nil && !r.text.contains("INVENTED-SECRET"))
        // A plain note with field-like lines stays a note.
        let note = Extractor.extract(Data("Item: invented chair\nPrice: 40 dollars\n\nPick up on Saturday.".utf8), name: "note.txt")
        #expect(note.kind == "text" && note.problem == nil && note.text.contains("Pick up on Saturday"))
    }

    // MARK: - 3. A quoted file name is one name, semicolons and escapes included

    @Test func aQuotedSemicolonDoesNotHideAKeyFile() throws {
        let eml = """
        From: manager@example.com
        Subject: Invented report
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        The invented report is attached.
        --XYZ
        Content-Type: text/plain
        Content-Disposition: attachment; filename="report;private.key"

        -----BEGIN INVENTED KEY----- INVENTED-SECRET-8301
        --XYZ
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="invented \\"Q4\\"; summary.pdf"; size=12

        JVBERi0xLjQK
        --XYZ--
        """
        let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
        let attachments = extracted.email?.attachments ?? []
        #expect(attachments.map(\.name) == ["report;private.key", "invented \"Q4\"; summary.pdf"])
        #expect(attachments.first?.data.isEmpty == true)
        let r = try readMessage(eml)
        #expect(!r.text.contains("INVENTED-SECRET"))
        #expect(r.notes.contains { $0.contains("report;private.key") && $0.contains("key or credential file") }, "\(r.notes)")
    }

    // MARK: - 4. A reading cut by the text limit is held

    @Test func aTextCutByTheLimitIsHeld() throws {
        var limits = Extractor.Limits()
        limits.textChars = 100
        let cut = Extractor.extract(Data((String(repeating: "invented ", count: 20) + "due November 9").utf8), name: "note.txt", limits: limits)
        #expect(cut.problem?.contains("text limit") == true)
        #expect(Extractor.extract(Data("A short invented note.".utf8), name: "note.txt", limits: limits).problem == nil)
        // At the real limit: a long file with a deadline at its end is held, not read as if it were whole.
        let url = temp("long").appendingPathComponent("long.txt")
        try Data((String(repeating: "x", count: Extractor.Limits().textChars) + "\nPay by November 9, 2026.").utf8).write(to: url)
        let r = IntakeReading.read(url, channel: "other", reader: .inProcess)
        #expect(r.held?.contains("text limit") == true)
    }

    // MARK: - 5. Every page of a TIFF is read

    @Test func everyPageOfATIFFIsRead() throws {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(dest, Fixtures.textImage(["Invented lease page one"]), nil)
        CGImageDestinationAddImage(dest, Fixtures.textImage(["Rent due November 1"]), nil)
        #expect(CGImageDestinationFinalize(dest))
        let r = Extractor.extract(data as Data, name: "lease.tiff")
        #expect(r.kind == "image" && r.pages == 2 && r.problem == nil)
        #expect(r.text.lowercased().contains("page one") && r.text.lowercased().contains("november"), "\(r.text)")
    }

    // MARK: - 6. An office part that does not read holds the document

    func breaking(_ part: String, in zip: Data) throws -> Data {
        let entry = try #require(Zip.entries(zip)?.first { $0.name == part })
        var broken = zip
        broken[entry.offset] = 0   // the local header no longer reads
        return broken
    }

    @Test func anUnreadableOfficePartHoldsTheDocument() throws {
        let xlsx = try Fixtures.zip([
            ("xl/workbook.xml", "<workbook/>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c><v>100</v></c></row></sheetData></worksheet>"),
            ("xl/worksheets/sheet2.xml", "<worksheet><sheetData><row><c><v>200</v></c></row></sheetData></worksheet>"),
        ])
        #expect(Extractor.extract(xlsx, name: "budget.xlsx").text == "100\n200")
        let sheet = Extractor.extract(try breaking("xl/worksheets/sheet2.xml", in: xlsx), name: "budget.xlsx")
        #expect(sheet.problem?.contains("sheet2.xml") == true && sheet.text.isEmpty)
        let pptx = try Fixtures.zip([
            ("ppt/slides/slide1.xml", "<p:sld><a:p><a:r><a:t>Invented agenda</a:t></a:r></a:p></p:sld>"),
            ("ppt/slides/slide2.xml", "<p:sld><a:p><a:r><a:t>Vote on the invented budget</a:t></a:r></a:p></p:sld>"),
        ])
        #expect(Extractor.extract(pptx, name: "agenda.pptx").text == "Invented agenda\n\nVote on the invented budget")
        let slide = Extractor.extract(try breaking("ppt/slides/slide2.xml", in: pptx), name: "agenda.pptx")
        #expect(slide.problem?.contains("slide2.xml") == true && slide.text.isEmpty)
    }

    // MARK: - 8. Word text comes from `w:t` alone, never from tables or tabs

    @Test func aWordTableGivesOnlyItsText() throws {
        let docx = try Fixtures.zip([
            ("word/document.xml", #"<w:document><w:body><w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:r><w:t>Invented repairs</w:t></w:r></w:p><w:tbl><w:tblPr><w:tblW w:w="0"/></w:tblPr><w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>Roof</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:tab/><w:t xml:space="preserve">4200</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#),
        ])
        let r = Extractor.extract(docx, name: "repairs.docx")
        #expect(r.text == "Invented repairs\nRoof\n4200", "\(r.text)")
    }
}
