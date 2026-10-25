import Foundation

/// App-owned read-only raw-message exporter. Runs isolated stdlib only; no legacy MIME conversion.
enum IMAPExporterSource {
    static let script = #"""
"""Sprava's isolated, read-only IMAP fetcher. TECAS .env keys; complete raw EML only.
No profiles, imported code, shell, logs, message parsing, flags or server mutations.
"""
import argparse
import base64
import imaplib
import json
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import sys
import time

MAX_MAIL = 64 * 1024 * 1024
CHUNK = 1024 * 1024
END = time.monotonic() + 240
imaplib._MAXLINE = 65536
_read = imaplib.IMAP4.read


def bounded_read(self, size):
    if size < 0 or size > CHUNK:
        raise ValueError("literal limit")
    return _read(self, size)


imaplib.IMAP4.read = bounded_read


def environment(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 131072:
            raise ValueError("private environment required")
        text = os.read(fd, 131073).decode("utf-8-sig")
    finally:
        os.close(fd)
    values, literal = {}, set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", key):
            raise ValueError("invalid environment")
        if value.startswith('"'):
            # dotenv's common quoted escapes; no command substitution or process environment.
            value, consumed = json.JSONDecoder().raw_decode(value)
            tail = line.partition("=")[2].strip()[consumed:].strip()
            if tail and not tail.startswith("#"):
                raise ValueError("invalid quoted suffix")
        elif value.startswith("'"):
            if not value.endswith("'") or len(value) < 2:
                raise ValueError("invalid quoted value")
            value = value[1:-1]
            literal.add(key)
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
        if not isinstance(value, str) or len(value) > 16384:
            raise ValueError("invalid value")
        values[key] = value
    for _ in range(8):
        changed = False
        for key, value in list(values.items()):
            if key in literal:
                continue
            replaced = re.sub(r"\$\{([A-Za-z_][A-Za-z_0-9]*)\}", lambda m: values.get(m.group(1), ""), value)
            changed = changed or replaced != value
            values[key] = replaced
        if not changed:
            break
    else:
        raise ValueError("environment expansion cycle")
    for key in ("IMAP_HOST", "IMAP_USER", "IMAP_PASSWORD"):
        value = values.get(key, "")
        if not value or (key not in literal and re.search(r"\$\{[A-Za-z_][A-Za-z_0-9]*\}", value)) or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("missing IMAP setting")
    return {key: values[key] for key in ("IMAP_HOST", "IMAP_USER", "IMAP_PASSWORD")}


def mailbox_name(value):
    # IMAP modified UTF-7: printable ASCII remains literal, '&' is '&-'.
    output, pending = [], []
    def flush():
        if pending:
            output.append("&" + base64.b64encode("".join(pending).encode("utf-16be")).decode().rstrip("=").replace("/", ",") + "-")
            pending.clear()
    for char in value:
        if 32 <= ord(char) <= 126:
            flush()
            output.append("&-" if char == "&" else char)
        else:
            pending.append(char)
    flush()
    result = "".join(output)
    return '"' + result.replace("\\", "\\\\").replace('"', '\\"') + '"'


def atomic(path, data):
    temporary = path.with_name(path.name + ".pending")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def checked(code, data):
    if code != "OK":
        raise ValueError("IMAP refused")
    if time.monotonic() > END:
        raise TimeoutError()
    return data


def quoted(value):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("control character")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class AuthenticationRefused(Exception):
    pass


def synchronize(session, folder, target, credentials, search="", sender="", subject=""):
    for value in (folder, search, sender, subject):
        if len(value) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("invalid filter")
    try:
        checked(*session.login(quoted(credentials["IMAP_USER"]), credentials["IMAP_PASSWORD"]))
    except (imaplib.IMAP4.error, ValueError) as error:
        raise AuthenticationRefused() from error
    checked(*session.select(mailbox_name(folder), readonly=True))
    kind, values = session.response("UIDVALIDITY")
    validity = int(values[0]) if kind == "UIDVALIDITY" and values else 0
    kind, values = session.response("UIDNEXT")
    following = int(values[0]) if kind == "UIDNEXT" and values else 0
    if not 0 < validity <= 4294967295 or not 0 < following <= 4294967295:
        raise ValueError("invalid mailbox generation")
    cursor_path = Path("state.json")
    cursor = json.loads(cursor_path.read_bytes()) if cursor_path.exists() else None
    if cursor is not None and (set(cursor) != {"uid_validity", "last_seen_uid"} or type(cursor["last_seen_uid"]) is not int or not 0 <= cursor["last_seen_uid"] <= 4294967295):
        raise ValueError("invalid cursor")
    def acknowledge(uid):
        atomic(cursor_path, json.dumps({"uid_validity": validity, "last_seen_uid": uid}).encode())
    if cursor is None or cursor["uid_validity"] != validity:
        acknowledge(following - 1)
        return
    previous, completed = cursor["last_seen_uid"], 0
    while previous < following - 1 and completed < 32:
        upper = min(previous + 2048, following - 1)
        terms = ["UID " + str(previous + 1) + ":" + str(upper)]
        if search:
            terms.append("(" + search + ")")
        if sender:
            terms.append("FROM " + quoted(sender))
        if subject:
            terms.append("SUBJECT " + quoted(subject))
        query = " ".join(terms)
        args = (None, query) if query.isascii() else ("CHARSET", "UTF-8", query.encode("utf-8"))
        found = checked(*session.uid("SEARCH", *args))
        uids = sorted(set(int(value) for value in b" ".join(found).split()))
        if len(uids) > 2048 or any(not previous < uid <= upper for uid in uids):
            raise ValueError("UID limit")
        for uid in uids:
            metadata = checked(*session.uid("FETCH", str(uid), "(RFC822.SIZE)"))
            match = re.search(rb"RFC822.SIZE\s+(\d+)", b" ".join(part for part in metadata if isinstance(part, bytes)))
            size = int(match.group(1)) if match else 0
            if not 0 < size <= MAX_MAIL:
                raise ValueError("message size limit")
            body = bytearray()
            while len(body) < size:
                remaining = min(CHUNK, size - len(body))
                response = checked(*session.uid("FETCH", str(uid), "(BODY.PEEK[]<" + str(len(body)) + "." + str(remaining) + ">)"))
                literals = [part[1] for part in response if isinstance(part, tuple) and len(part) == 2 and isinstance(part[1], bytes)]
                if len(literals) != 1 or not 0 < len(literals[0]) <= remaining:
                    raise ValueError("incomplete literal")
                body.extend(literals[0])
            atomic(target / ("mail-" + str(uid) + ".eml"), body)
            acknowledge(uid)
            completed += 1
            if completed == 32:
                return
        acknowledge(upper)
        previous = upper


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--folder", required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--env-file", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--starttls", action="store_true")
    parser.add_argument("--search", default="")
    parser.add_argument("--from-contains", default="")
    parser.add_argument("--subject-contains", default="")
    args = parser.parse_args()
    credentials = environment(args.env_file)
    context = ssl.create_default_context()
    socket.setdefaulttimeout(20)
    host = credentials["IMAP_HOST"]
    if args.starttls:
        session = imaplib.IMAP4(host, args.port, timeout=20)
        checked(*session.starttls(ssl_context=context))
    else:
        session = imaplib.IMAP4_SSL(host, args.port, ssl_context=context, timeout=20)
    try:
        synchronize(session, args.folder, args.target, credentials, args.search, args.from_contains, args.subject_contains)
    finally:
        try:
            session.logout()
        except Exception:
            session.shutdown()


if __name__ == "__main__":
    try:
        main()
    except AuthenticationRefused:
        sys.exit(21)
    except BaseException:
        # Never print credentials, server metadata, message headers or provider errors.
        sys.exit(1)

"""#
}
