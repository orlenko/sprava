import Foundation

/// App-owned worker that places one approved draft in an account's Drafts folder (decisions.md D41). It shares the
/// read-only exporter's connection, sign-in and folder-name code, taken from that script unchanged so its pinned hash
/// stays the same, and adds the one change a draft needs: `APPEND` with `\Draft`. It never sends and never changes
/// a message already there.
enum IMAPDraftSource {
    /// The exporter's helpers: everything before its first mailbox operation.
    static let shared: String = {
        let script = IMAPExporterSource.script
        guard let end = script.range(of: "\ndef synchronize(") else { preconditionFailure("the exporter's helpers moved") }
        return String(script[..<end.lowerBound])
    }()

    static var script: String { shared + "\n\n" + tail }

    static let tail = #"""
DRAFT_LIMIT = 32 * 1024 * 1024
MESSAGE_ID = re.compile(r"<[\x21-\x3b\x3d\x3f-\x7e]{1,250}@[\x21-\x3b\x3d\x3f-\x7e]{1,250}>")
APPENDUID = re.compile(rb"\[APPENDUID \d+ (\d+)\]")


class NoDrafts(Exception):
    pass


def listed(session):
    for item in checked(*session.list()):
        head, literal = (item[0], item[1]) if isinstance(item, tuple) else (item, None)
        if not isinstance(head, bytes) or not head.strip() or head.strip() == b")":
            continue
        match = LISTED.match(head)
        if not match:
            raise ValueError("unreadable folder list")
        raw = literal if literal is not None else match.group(2)
        if raw.startswith(b'"'):
            if len(raw) < 2 or not raw.endswith(b'"'):
                raise ValueError("unreadable folder name")
            raw = re.sub(rb'\\(.)', rb'\1', raw[1:-1])
        try:
            name = decoded_name(raw.decode("utf-8"))
        except ValueError:
            continue
        yield match.group(1).lower().split(), name


def drafts_folder(session, chosen):
    # The folder the person chose, or the one the server marks \Drafts (RFC 6154); never a guess by name.
    if chosen:
        return chosen
    marked = [name for flags, name in listed(session) if b"\\drafts" in flags and b"\\noselect" not in flags]
    if len(marked) != 1:
        raise NoDrafts()
    return marked[0]


def place(session, credentials, chosen, message, message_id):
    if not MESSAGE_ID.fullmatch(message_id) or not 0 < len(message) <= DRAFT_LIMIT:
        raise ValueError("invalid draft")
    if len(chosen) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in chosen):
        raise ValueError("invalid folder")
    authenticate(session, credentials)
    folder = drafts_folder(session, chosen)
    # A retry finds the draft it placed before by its Message-ID, and places nothing again.
    checked(*session.select(mailbox_name(folder), readonly=True))
    found = checked(*session.uid("SEARCH", None, "HEADER", "Message-ID", quoted(message_id)))
    uids = [int(value) for value in b" ".join(part for part in found if isinstance(part, bytes)).split()]
    if uids:
        return {"folder": folder, "uid": uids[0], "present": True}
    response = checked(*session.append(mailbox_name(folder), "(\\Draft)", None, message))
    match = APPENDUID.search(b" ".join(part for part in response if isinstance(part, bytes)))
    return {"folder": folder, "uid": int(match.group(1)) if match else None, "present": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--starttls", action="store_true")
    parser.add_argument("--pin", default="")
    parser.add_argument("--folder", default="")
    parser.add_argument("--message-id", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9.:-]{1,253}", args.host) or not 0 < args.port < 65536:
        raise ValueError("invalid server")
    socket.setdefaulttimeout(20)
    account = credentials(sys.stdin.buffer)
    draft = Path("draft.eml")
    if draft.is_symlink() or not draft.is_file() or draft.stat().st_size > DRAFT_LIMIT:
        raise ValueError("invalid draft")
    message = draft.read_bytes()
    session = connect(args.host, args.port, args.starttls, args.pin)
    try:
        atomic(Path("result.json"), json.dumps(place(session, account, args.folder, message, args.message_id)).encode())
    finally:
        try:
            session.logout()
        except Exception:
            close(session)


if __name__ == "__main__":
    try:
        main()
    except AuthenticationRefused:
        sys.exit(21)
    except Untrusted:
        sys.exit(22)
    except NoDrafts:
        sys.exit(23)
    except BaseException:
        # Never print credentials, server metadata, message headers or provider errors.
        sys.exit(1)
"""#
}
