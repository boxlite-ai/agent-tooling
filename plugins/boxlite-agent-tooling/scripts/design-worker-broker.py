#!/usr/bin/env python3
"""Task-local read-only MCP tools. Public transport runs before private input exists."""
import hashlib
import ipaddress
import itertools
import json
import os
from pathlib import Path
import queue
import re
import socket
import stat
import subprocess
import threading
import time
from urllib.parse import unquote, urlencode, urlsplit

LIMIT = 65536
TOOLS = {
    "source_list": {"prefix": "string"},
    "source_search": {"query": "string"},
    "source_read": {"path": "string", "version": "string"},
    "source_history": {"path": "string", "limit": "integer"},
    "research_list": {},
    "research_read": {"id": "integer"},
}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def bounded(command, *, timeout=10, maximum=LIMIT, env=None, cwd=None):
    """Bound stdout while it streams, including responses without Content-Length."""
    with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, cwd=cwd) as child:
        output, errors = bytearray(), bytearray()
        overflow = threading.Event()

        def drain(stream, target):
            while True:
                block = stream.read(4096)
                if not block:
                    return
                if len(target) + len(block) > maximum:
                    overflow.set()
                    child.kill()
                    return
                target.extend(block)

        readers = [threading.Thread(target=drain, args=pair, daemon=True)
                   for pair in [(child.stdout, output), (child.stderr, errors)]]
        for reader in readers:
            reader.start()
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=2)
            raise ValueError("operation deadline exceeded") from None
        for reader in readers:
            reader.join(timeout=2)
        if overflow.is_set() or any(reader.is_alive() for reader in readers):
            raise ValueError("operation output exceeds limit")
        if code:
            raise ValueError("operation failed")
        return bytes(output), bytes(errors)


def public_fetch(url, curl, identifiers=()):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.port not in (None, 443) or parsed.fragment or len(url) > 2048
            or re.search(r"[\s\\\x00-\x1f]|(?:token|key|secret|password|email)=", url, re.I)):
        raise ValueError("unsupported public locator")
    decoded = url
    for _ in range(3):
        decoded = unquote(decoded)
    if unquote(decoded) != decoded:
        raise ValueError("ambiguous locator encoding")
    private = [Path.home().name, *identifiers]
    if (re.search(r"[\x00-\x1f\\]|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|(?:token|key|secret|password|email)=", decoded, re.I)
            or any(re.search(r"(?<![A-Za-z0-9])" + re.escape(value) + r"(?![A-Za-z0-9])", decoded, re.I)
                   for value in private if value)
            or not re.fullmatch(r"[A-Za-z0-9.-]+", parsed.hostname)):
        raise ValueError("private identifier or ambiguous locator")
    addresses = queue.Queue()

    def resolve():
        try:
            addresses.put(socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM))
        except OSError:
            addresses.put([])

    threading.Thread(target=resolve, daemon=True).start()
    answers = addresses.get(timeout=3)
    peers = {item[4][0] for item in answers}
    if not peers or any(not ipaddress.ip_address(peer).is_global or ipaddress.ip_address(peer).is_multicast for peer in peers):
        raise ValueError("public DNS required")
    ipv4 = sorted(peer for peer in peers if ipaddress.ip_address(peer).version == 4)
    if not ipv4:
        raise ValueError("public IPv4 required")
    peer = ipv4[0]
    environment = {key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}
    output, metadata = bounded([
        curl, "--disable", "--silent", "--show-error", "--fail", "--proto", "=https",
        "--proxy", "", "--noproxy", "*", "--max-redirs", "0", "--connect-timeout", "3",
        "--max-time", "5", "--max-filesize", str(LIMIT), "--resolve",
        f"{parsed.hostname}:443:{peer}", "--write-out", "%{stderr}\n%{remote_ip} %{http_code}", url,
    ], timeout=6, env=environment)
    if metadata.decode().strip() != f"{peer} 200":
        raise ValueError("unverified HTTPS peer or status")
    return output.decode("utf-8", errors="replace")


def prefetch(design_url, curl, deadline, identifiers=()):
    """Anonymous public proof authorizes a plan; private providers get no outbound plan."""
    match = re.fullmatch(r"https://github.com/([\w.-]+/[\w.-]+)/issues/([1-9][0-9]*)", design_url)
    if not match:
        return []
    try:
        public = json.loads(public_fetch(f"https://api.github.com/repos/{match[1]}/issues/{match[2]}", curl, identifiers))
        if public.get("html_url") != design_url or not isinstance(public.get("body"), str):
            return []
    except (ValueError, OSError, queue.Empty):
        return []
    # Payloads are constants or URLs already present in the anonymously readable design.
    term = "independent audit worker provenance task identity"
    urls = [
        "https://export.arxiv.org/api/query?" + urlencode({"search_query": "all:" + term, "max_results": 3}),
        "https://api.openalex.org/works?" + urlencode({"search": term, "per-page": 3}),
        "https://api.github.com/search/repositories?" + urlencode({"q": term, "per_page": 3}),
        "https://registry.npmjs.org/-/v1/search?" + urlencode({"text": term, "size": 3}),
        "https://www.google.com/search?" + urlencode({"q": term}),
    ]
    urls += re.findall(r"https://[^\s<>\])]+", public["body"])[:12]
    records = [{"id": 0, "url": design_url, "body": public["body"], "status": "public input"}]
    for url in dict.fromkeys(urls):
        if time.monotonic() >= deadline - 6:
            records.append({"id": len(records), "url": url, "status": "setup deadline"})
            continue
        try:
            text = public_fetch(url, curl, identifiers)
            records.append({"id": len(records), "url": url, "body": text, "status": "cached"})
        except (ValueError, OSError, queue.Empty):
            records.append({"id": len(records), "url": url, "status": "unavailable; stop"})
    return records


def git(command, root, git_binary, maximum=LIMIT, timeout=10):
    environment = {"PATH": os.defpath, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1"}
    for key in ("SystemRoot", "WINDIR"):
        if key in os.environ:
            environment[key] = os.environ[key]
    return bounded([git_binary, "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
                    "-c", "core.hooksPath=" + os.devnull, *command], cwd=root, env=environment, maximum=maximum, timeout=timeout)[0]


def sources(root, directory, git_binary):
    """Freeze tracked regular files and committed blobs; never follow checkout links."""
    manifest = {}
    current = git(["ls-files", "--stage", "-z"], root, git_binary, 1048576).split(b"\0")
    if len(current) > 10001:
        raise ValueError("tracked source count exceeds limit")
    total = 0
    for entry in current:
        if not entry:
            continue
        header, raw_path = entry.split(b"\t", 1)
        mode, oid, stage = header.decode().split()
        path = raw_path.decode("utf-8")
        if mode not in ("100644", "100755") or stage != "0" or "\n" in path:
            continue
        candidate = root / path
        if candidate.is_symlink() or any(parent.is_symlink() for parent in candidate.parents if parent != root.parent):
            continue
        try:
            descriptor = os.open(candidate, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        except FileNotFoundError:
            continue
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                continue
            data = stream.read(LIMIT + 1)
        if len(data) > LIMIT or b"\0" in data:
            continue
        total += len(data)
        if total > 16 * 1024 * 1024:
            raise ValueError("tracked source snapshot exceeds limit")
        manifest[path] = {"current": data.decode("utf-8", errors="replace")}
    # A clean object reader ignores local grafts, replacements, hooks, and filters.
    object_dir = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], root, git_binary).decode().strip()
    if "\n" in object_dir:
        raise ValueError("unsupported Git object path")
    history = directory / "history.git"
    object_format = git(["rev-parse", "--show-object-format"], root, git_binary).decode().strip()
    git(["init", "--bare", "--object-format=" + object_format, str(history)], directory, git_binary)
    (history / "objects/info/alternates").write_text(str(Path(object_dir) / "objects") + "\n")
    head = git(["rev-parse", "HEAD"], root, git_binary).decode().strip()
    for entry in git(["--git-dir=" + str(history), "ls-tree", "-rz", head], directory, git_binary, 1048576).split(b"\0"):
        if not entry:
            continue
        header, name = entry.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        path = name.decode("utf-8")
        if mode not in ("100644", "100755") or kind != "blob":
            continue
        try:
            data = git(["--git-dir=" + str(history), "cat-file", "blob", oid], directory, git_binary)
            if b"\0" not in data:
                total += len(data)
                if total > 32 * 1024 * 1024:
                    raise OverflowError("tracked source snapshot exceeds limit")
                manifest.setdefault(path, {})["base"] = data.decode("utf-8", errors="replace")
        except ValueError:
            pass  # The path remains discoverable only when bounded textual content exists.
    return {"files": manifest, "history": str(history), "head": head, "git": git_binary}


def call(data, name, arguments):
    if name not in TOOLS or not isinstance(arguments, dict) or set(arguments) != set(TOOLS[name]):
        raise ValueError("unknown tool or argument")
    for key, expected in TOOLS[name].items():
        value = arguments[key]
        if expected == "string" and (not isinstance(value, str) or len(value) > 256 or "\0" in value):
            raise ValueError("invalid string argument")
        if expected == "integer" and (type(value) is not int or not 0 <= value <= 100):
            raise ValueError("invalid integer argument")
    files = data["sources"]["files"]
    if name == "source_list":
        return [path for path in files if path.startswith(arguments["prefix"])][:100]
    if name == "source_search":
        term = arguments["query"]
        if not term:
            raise ValueError("search term required")
        return list(itertools.islice(({"path": path, "line": i + 1, "text": line[:500]}
                for path, versions in files.items()
                for i, line in enumerate(versions.get("current", "").splitlines()) if term in line), 50))
    if name == "source_read":
        if arguments["version"] not in ("current", "base"):
            raise ValueError("unknown source version")
        if arguments["path"] not in files or arguments["version"] not in files[arguments["path"]]:
            raise ValueError("not a bounded tracked regular blob")
        return files[arguments["path"]][arguments["version"]]
    if name == "source_history":
        if arguments["path"] not in files or not 1 <= arguments["limit"] <= 10:
            raise ValueError("tracked path and history limit 1..10 required")
        source = data["sources"]
        return git(["--git-dir=" + source["history"], "log", "--no-show-signature", "--format=%H %s",
                    "-n", str(arguments["limit"]), source["head"], "--", arguments["path"]],
                   Path(source["history"]).parent, source["git"], timeout=max(0.01, min(10, data["cutoff"] - time.monotonic()))).decode()
    if name == "research_list":
        return [{key: value for key, value in item.items() if key != "body"} for item in data["research"]]
    return next(item for item in data["research"] if item["id"] == arguments["id"])


def serve(path):
    data = json.loads(Path(path).read_text())
    calls = 0
    for line in iter(lambda: __import__("sys").stdin.buffer.readline(LIMIT + 1), b""):
        if len(line) > LIMIT:
            raise ValueError("MCP input exceeds limit")
        request = json.loads(line)
        if "id" not in request:
            continue
        allowed = False
        try:
            method = request["method"]
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "design-probe", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [{"name": name, "description": "Read the assigned immutable " + name,
                    "inputSchema": {"type": "object", "properties": {key: {"type": kind} for key, kind in fields.items()},
                                    "required": list(fields), "additionalProperties": False},
                    "annotations": {"readOnlyHint": True, "destructiveHint": False,
                                    "idempotentHint": True, "openWorldHint": False}} for name, fields in TOOLS.items()]}
            elif method == "tools/call":
                calls += 1
                if calls > 512 or time.monotonic() >= data["cutoff"]:
                    raise ValueError("research deadline passed; return the final JSON")
                value = call(data, request["params"]["name"], request["params"].get("arguments", {}))
                allowed = True
                result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
            elif method == "ping":
                result = {}
            else:
                raise ValueError("unsupported MCP operation")
            response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        except (ValueError, KeyError, StopIteration):
            response = {"jsonrpc": "2.0", "id": request["id"],
                        "error": {"code": -32602, "message": "Request denied by task broker"}}
        if request.get("method") == "tools/call" and calls <= 513:
            name = request.get("params", {}).get("name")
            with open(data["events"], "a", encoding="utf-8") as events:
                events.write(json.dumps({"tool": name if name in TOOLS else "unsupported", "allowed": allowed}) + "\n")
        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    serve(__import__("sys").argv[1])
