import Foundation

/// App-owned read-only raw-message exporter. Runs isolated stdlib only; no legacy MIME conversion.
enum IMAPExporterSource {
    static let script = #"""
"""Sprava's isolated, read-only IMAP worker: probes a server, lists its folders, or exports complete raw EML.
Credentials arrive on stdin, never argv, environment or a file. No profiles, imported code, shell, logs,
message parsing, flags or server mutations.
"""
import argparse
import base64
import hashlib
import imaplib
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
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


class AuthenticationRefused(Exception):
    pass


class Untrusted(Exception):
    pass


def plain(value, limit):
    if not isinstance(value, str) or not value or len(value) > limit or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid credential")
    return value


def credentials(stream):
    data = stream.read(65537)
    if len(data) > 65536:
        raise ValueError("credential limit")
    value = json.loads(data.decode("utf-8"))
    if not isinstance(value, dict) or set(value) != {"user", "password"}:
        raise ValueError("invalid credentials")
    return {"user": plain(value["user"], 1024), "password": plain(value["password"], 4096)}


def loopback(host):
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def verified():
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def unverified():
    # Only to read a certificate's fingerprint, or with a fingerprint pinned for this Mac's own bridge.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def close(session):
    # After a failed handshake the socket is already gone; closing must never hide the error that matters.
    try:
        session.shutdown()
    except Exception:
        pass


def open_session(host, port, starttls, context, timeout):
    if starttls:
        session = imaplib.IMAP4(host, port, timeout=timeout)
        try:
            if "STARTTLS" not in session.capabilities:
                raise ssl.SSLError("STARTTLS not offered")
            checked(*session.starttls(ssl_context=context))
        except BaseException:
            close(session)
            raise
        return session
    return imaplib.IMAP4_SSL(host, port, ssl_context=context, timeout=timeout)


def fingerprint(session):
    certificate = session.sock.getpeercert(binary_form=True)
    if not certificate:
        raise Untrusted()
    return hashlib.sha256(certificate).hexdigest()


def connect(host, port, starttls, pin):
    if not pin:
        return open_session(host, port, starttls, verified(), 20)
    if not loopback(host) or not re.fullmatch(r"[0-9a-f]{64}", pin):
        raise ValueError("a pinned certificate is only for this Mac's own bridge")
    session = open_session(host, port, starttls, unverified(), 20)
    # Nothing but the greeting and capabilities has crossed before this check; credentials never do.
    if fingerprint(session) != pin:
        close(session)
        raise Untrusted()
    return session


def probe(host, port, starttls):
    try:
        session = open_session(host, port, starttls, verified(), 8)
    except ssl.SSLCertVerificationError:
        try:
            session = open_session(host, port, starttls, unverified(), 8)
        except ssl.SSLError:
            return {"result": "tls"}
        except Exception:
            return {"result": "not_imap"}
        try:
            value = fingerprint(session)
        finally:
            close(session)
        return {"result": "untrusted", "fingerprint": value}
    except socket.gaierror:
        return {"result": "unknown_host"}
    except (socket.timeout, TimeoutError):
        return {"result": "no_answer"}
    except ssl.SSLError:
        return {"result": "tls"}
    except ConnectionError:
        return {"result": "unreachable"}
    except (imaplib.IMAP4.error, ValueError, EOFError):
        return {"result": "not_imap"}
    except OSError:
        return {"result": "unreachable"}
    capabilities = session.capabilities
    try:
        session.logout()
    except Exception:
        close(session)
    password = "LOGINDISABLED" not in capabilities or "AUTH=PLAIN" in capabilities
    return {"result": "ok" if password else "oauth_only"}


def authenticate(session, credentials):
    try:
        if "LOGINDISABLED" in session.capabilities:
            if "AUTH=PLAIN" not in session.capabilities:
                raise ValueError("no password sign-in")
            token = ("\0" + credentials["user"] + "\0" + credentials["password"]).encode("utf-8")
            checked(*session.authenticate("PLAIN", lambda _: token))
        else:
            checked(*session.login(quoted(credentials["user"]), credentials["password"]))
    except (imaplib.IMAP4.error, ValueError) as error:
        raise AuthenticationRefused() from error


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


def decoded_name(value):
    output, index = [], 0
    while index < len(value):
        char = value[index]
        if char != "&":
            output.append(char)
            index += 1
            continue
        end = value.index("-", index)
        chunk = value[index + 1:end]
        if chunk:
            chunk = chunk.replace(",", "/")
            output.append(base64.b64decode(chunk + "=" * (-len(chunk) % 4), validate=True).decode("utf-16be"))
        else:
            output.append("&")
        index = end + 1
    return "".join(output)


LISTED = re.compile(rb'\(([^)]*)\) (?:NIL|"(?:[^"\\]|\\.)*") ?(.*)$')


def folders(session, credentials):
    authenticate(session, credentials)
    names = []
    for item in checked(*session.list()):
        head, literal = (item[0], item[1]) if isinstance(item, tuple) else (item, None)
        if not isinstance(head, bytes) or not head.strip() or head.strip() == b")":
            continue
        match = LISTED.match(head)
        if not match:
            raise ValueError("unreadable folder list")
        flags = match.group(1).lower().split()
        if b"\\noselect" in flags or b"\\nonexistent" in flags:
            continue
        raw = literal if literal is not None else match.group(2)
        if raw.startswith(b'"'):
            if len(raw) < 2 or not raw.endswith(b'"'):
                raise ValueError("unreadable folder name")
            raw = re.sub(rb'\\(.)', rb'\1', raw[1:-1])
        try:
            name = decoded_name(raw.decode("utf-8"))
        except ValueError:
            continue  # A name Sprava could not encode back the same way is not offered.
        if not name or len(name) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in name):
            continue
        names.append(name)
        if len(names) > 2000:
            raise ValueError("folder limit")
    unique = sorted(set(names), key=lambda name: (name.upper() != "INBOX", name.casefold()))
    return unique


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


def synchronize(session, folder, target, credentials, search="", sender="", subject=""):
    for value in (folder, search, sender, subject):
        if len(value) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("invalid filter")
    authenticate(session, credentials)
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
    parser.add_argument("--mode", choices=["probe", "folders", "sync"], required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--starttls", action="store_true")
    parser.add_argument("--pin", default="")
    parser.add_argument("--folder", default="")
    parser.add_argument("--target", type=Path)
    parser.add_argument("--search", default="")
    parser.add_argument("--from-contains", default="")
    parser.add_argument("--subject-contains", default="")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9.:-]{1,253}", args.host) or not 0 < args.port < 65536:
        raise ValueError("invalid server")
    socket.setdefaulttimeout(20)
    if args.mode == "probe":
        atomic(Path("result.json"), json.dumps(probe(args.host, args.port, args.starttls)).encode())
        return
    account = credentials(sys.stdin.buffer)
    session = connect(args.host, args.port, args.starttls, args.pin)
    try:
        if args.mode == "folders":
            atomic(Path("result.json"), json.dumps({"folders": folders(session, account)}).encode())
        else:
            if not args.folder or args.target is None:
                raise ValueError("folder and target required")
            synchronize(session, args.folder, args.target, account, args.search, args.from_contains, args.subject_contains)
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
    except BaseException:
        # Never print credentials, server metadata, message headers or provider errors.
        sys.exit(1)

"""#
}
