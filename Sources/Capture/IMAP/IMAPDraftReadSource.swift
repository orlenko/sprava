import Foundation

/// Builds on the isolated IMAP worker's connection helpers and the approved-message comparison fields.
enum IMAPDraftReadSource {
    static var script: String {
        let common = IMAPDraftSource.tail
        guard let end = common.range(of: "\ndef place(") else { preconditionFailure("draft worker helpers moved") }
        return IMAPDraftSource.shared + "\n" + String(common[..<end.lowerBound]) + "\n" + tail
    }

    static let tail = #"""
from email.message import EmailMessage


class BoundedMessage(EmailMessage):
    """The feed parser creates a fresh message for every MIME part, including nested ones."""
    def set_raw(self, name, value):
        # The parser supplies an unfolded name and the raw (possibly folded) value, before
        # decoding structured fields or looking for a multipart boundary. Count each entity
        # independently so body text and attachment bytes do not count as headers.
        used = getattr(self, "_raw_header_bytes", 0) + len(name) + len(value) + 4
        if used > 65536:
            raise ValueError("MIME part headers exceed the comparison limit")
        self._raw_header_bytes = used
        super().set_raw(name, value)


def result(status, differences=()):
    return {"status": status, "differences": list(differences)}


def read_one(session, folder, approved):
    message_id = approved["messageID"]
    if not MESSAGE_ID.fullmatch(message_id):
        raise ValueError("invalid message id")
    checked(*session.select(mailbox_name(folder), readonly=True))
    found = checked(*session.uid("SEARCH", None, "HEADER", "Message-ID", quoted(message_id)))
    candidates = b" ".join(p for p in found if isinstance(p, bytes)).split()
    if len(candidates) > 20:
        return result("ambiguous")
    exact = []
    for candidate in candidates:
        if not re.fullmatch(rb"[1-9][0-9]{0,9}", candidate) or int(candidate) > 4294967295:
            return result("unreadable")
        uid = candidate.decode("ascii")
        header = checked(*session.uid("FETCH", uid, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"))
        if header_id(header) == message_id:
            exact.append(uid)
    if len(exact) != 1:
        return result("ambiguous" if exact else "missing")

    uid = exact[0]
    meta = checked(*session.uid("FETCH", uid, "(RFC822.SIZE)"))
    size_match = re.search(rb"RFC822.SIZE\s+(\d+)", b" ".join(p for p in meta if isinstance(p, bytes)))
    size = int(size_match.group(1)) if size_match else 0
    if not 0 < size <= DRAFT_LIMIT:
        return result("unreadable")
    data = bytearray()
    while len(data) < size:
        count = min(CHUNK, size - len(data))
        # Ask for one extra byte on the last chunk so a short advertised size cannot truncate a comparison.
        requested = count + 1 if len(data) + count == size else count
        response = checked(*session.uid("FETCH", uid, "(BODY.PEEK[]<%d.%d>)" % (len(data), requested)))
        blocks = [p[1] for p in response if isinstance(p, tuple) and len(p) == 2 and isinstance(p[1], bytes)]
        if len(blocks) != 1 or len(blocks[0]) != count:
            return result("unreadable")
        data.extend(blocks[0])

    # Sprava's own headers are bounded. Decline excessive header work before the MIME parser decodes fields.
    if data.find(b"\r\n\r\n", 0, 65540) < 0 and data.find(b"\n\n", 0, 65538) < 0:
        return result("unreadable")
    try:
        message = BytesParser(_class=BoundedMessage, policy=policy.default).parsebytes(bytes(data))
        if message.get_all("Message-ID", []) != [message_id] or any(len(message.get_all(h, [])) > 1 for h in ("Subject", "To", "Cc", "Bcc")):
            return result("unreadable")
        # Only a plain body and simple attachments can be called equivalent to the draft Sprava builds.
        # For other MIME layouts the UI reports that Sprava could not compare them.
        if message.is_multipart() and message.get_content_type() != "multipart/mixed":
            return result("unreadable")
        parts = list(message.iter_parts()) if message.is_multipart() else [message]
        if not parts or parts[0].get_content_type() != "text/plain" or len(parts) > 101:
            return result("unreadable")
        if any(p.is_multipart() or p.defects for p in parts) or any(p.get_content_disposition() != "attachment" for p in parts[1:]):
            return result("unreadable")
        fields = message_fields(message)
        differs = []
        if message.get_all("Bcc") or any(sorted(fields[k]) != sorted(approved[k]) for k in ("to", "cc")):
            differs.append("recipients")
        if fields["subject"] != approved["subject"]:
            differs.append("subject")
        if fields["bodyHash"] != approved["bodyHash"]:
            differs.append("body")
        if sorted(fields["attachmentHashes"]) != sorted(approved["attachmentHashes"]):
            differs.append("attachments")
        return result("matched", differs)
    except (ValueError, LookupError, TypeError, UnicodeError, AttributeError, RecursionError):
        return result("unreadable")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--starttls", action="store_true")
    parser.add_argument("--pin", default="")
    parser.add_argument("--folder", required=True)
    args = parser.parse_args()
    approved = json.loads(Path("approved.json").read_bytes())
    account = credentials(sys.stdin.buffer)
    socket.setdefaulttimeout(20)
    session = connect(args.host, args.port, args.starttls, args.pin)
    try:
        authenticate(session, account)
        atomic(Path("result.json"), json.dumps(read_one(session, args.folder, approved)).encode())
    finally:
        close(session)


if __name__ == "__main__":
    try:
        main()
    except AuthenticationRefused:
        sys.exit(21)
    except Untrusted:
        sys.exit(22)
    except BaseException:
        sys.exit(1)
"""#
}
