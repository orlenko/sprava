/// Account setup lists selectable folders once. It returns their names and a unique Sent designation.
enum IMAPFolderListingSource {
    static let script = IMAPExporterSource.preamble + "\n\n" + listed + "\n\n" + folderRows + "\n\n" + IMAPExporterSource.workerMain

    static let listed = #"""
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
        flags = match.group(1).lower().split()
        # As the exporter's folder list: no unselectable, missing, overlong or control-character names.
        if b"\\noselect" in flags or b"\\nonexistent" in flags or not name or len(name) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in name):
            continue
        yield flags, name
"""#

    private static let folderRows = #"""
def folders(session, credentials):
    authenticate(session, credentials)
    names = set()
    marked = set()
    for count, (flags, name) in enumerate(listed(session), 1):
        if count > 2000:
            raise ValueError("folder limit")
        if len(name.encode("utf-8")) > 1024:
            continue
        names.add(name)
        if b"\\sent" in flags:
            marked.add(name)
    ordered = sorted(names, key=lambda name: (name.upper() != "INBOX", name.casefold(), name))
    return [{"name": name, "sent": name in marked} for name in ordered]
"""#
}
