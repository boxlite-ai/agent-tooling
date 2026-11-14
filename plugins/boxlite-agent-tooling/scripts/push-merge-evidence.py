#!/usr/bin/env python3
"""Optional, bounded evidence for a merge of history advertised by the receiving service."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

PLUGIN = Path(__file__).resolve().parent.parent
EVIDENCE_LIMIT = 262144
TREE_LIMIT = 16777216


def execute(argv, environment, deadline, maximum=EVIDENCE_LIMIT, data=b"", owner=None):
    child = owner.launch(argv, environment) if owner else subprocess.Popen(
        argv, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, errors, failed = bytearray(), bytearray(), threading.Event()

    def drain(stream, target, limit):
        for block in iter(lambda: stream.read(4096), b""):
            if len(target) + len(block) > limit:
                failed.set()
                child.kill()
                return
            target.extend(block)

    def send():
        try:
            child.stdin.write(data)
            child.stdin.close()
        except OSError:
            failed.set()

    threads = [threading.Thread(target=drain, args=(child.stdout, output, maximum), daemon=True),
               threading.Thread(target=drain, args=(child.stderr, errors, 8192), daemon=True),
               threading.Thread(target=send, daemon=True)]
    for thread in threads:
        thread.start()
    try:
        code = child.wait(timeout=max(0.001, deadline - time.monotonic()))
    finally:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=2)
        for thread in threads:
            thread.join(timeout=0.1)
        child.stdout.close()
        child.stderr.close()
    if code or failed.is_set() or any(thread.is_alive() for thread in threads):
        raise ValueError("incomplete operation")
    return bytes(output)


def advertisement(response):
    headers, body = response.split(b"\r\n\r\n", 1)
    lines = headers.split(b"\r\n")
    if not re.fullmatch(rb"HTTP/(?:1\.[01]|2) 200(?: .*)?", lines[0]):
        raise ValueError("receiving HTTP status")
    types = [line.split(b":", 1)[1].strip().lower() for line in lines[1:]
             if line.lower().startswith(b"content-type:")]
    if types != [b"application/x-git-receive-pack-advertisement"]:
        raise ValueError("receiving content type")
    packets = []
    while body:
        if len(body) < 4 or not re.fullmatch(b"[0-9a-fA-F]{4}", body[:4]):
            raise ValueError("packet framing")
        size = int(body[:4], 16)
        if size == 0:
            packets.append(None)
            body = body[4:]
        elif 4 < size <= len(body):
            packets.append(body[4:size])
            body = body[size:]
        else:
            raise ValueError("partial packet")
    if (packets[:2] != [b"# service=git-receive-pack\n", None]
            or len(packets) < 4 or packets[-1] is not None):
        raise ValueError("receiving service")
    refs = {}
    for index, packet in enumerate(packets[2:-1]):
        if packet is None or (b"\0" in packet and index != 0):
            raise ValueError("ref framing")
        record = packet.split(b"\0", 1)[0].rstrip(b"\n")
        match = re.fullmatch(rb"([0-9a-f]{40}) (refs/[^\x00-\x20\x7f]+|\.have)", record)
        if not match:
            raise ValueError("advertised ref")
        oid, ref = match.groups()
        if ref != b".have":
            if ref in refs:
                raise ValueError("duplicate ref")
            refs[ref] = oid.decode()
    return refs


def select_entries(base, first, second, result):
    """Overlaps require review even when both result deltas are empty."""
    for path in sorted(set(base) | set(first) | set(second) | set(result)):
        b, f, p, r = (tree.get(path) for tree in (base, first, second, result))
        overlap = f != b and p != b
        expected = f if f != b else p
        if overlap or r != expected:
            yield path, "overlap" if overlap else "result differs from inherited entry", [b, f, p, r]


def read_trees(git, oids):
    trees, total = [], 0
    for oid in oids:
        raw = git("ls-tree", "-rz", "--full-tree", oid, maximum=TREE_LIMIT - total)
        total += len(raw)
        entries = {}
        for entry in raw.split(b"\0")[:-1]:
            metadata, path = entry.split(b"\t", 1)
            entries[path] = metadata.decode().split()
        trees.append(entries)
    return trees


def restored_search_path():
    path = os.environ.get("PATH", os.defpath)
    helper = os.environ.get("GIT_EXEC_PATH")
    if helper is None:
        return path
    if (not helper or not Path(helper).is_absolute() or os.pathsep in helper
            or any(ord(c) < 32 or ord(c) == 127 for c in helper + path)):
        raise ValueError("ambiguous Git helper path")
    directory = Path(helper).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("unavailable Git helper directory")
    entries = path.split(os.pathsep)
    if any(not entry or not Path(entry).is_absolute() for entry in entries):
        raise ValueError("ambiguous executable search path")
    # Git prepends this unproved directory; aliases must not reintroduce it.
    return os.pathsep.join(entry for entry in entries if not Path(entry).resolve().is_relative_to(directory))


def local_tool(name, environment):
    binary = shutil.which(name, path=environment["PATH"])
    helper = os.environ.get("GIT_EXEC_PATH")
    if (not binary or (helper is not None
            and Path(binary).resolve().is_relative_to(Path(helper).resolve()))):
        raise ValueError("unavailable trusted local tool")
    return binary


def proof_environment():
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    if "GIT_CONFIG_NOSYSTEM" in os.environ:
        environment["GIT_CONFIG_NOSYSTEM"] = os.environ["GIT_CONFIG_NOSYSTEM"]
    environment.update(PATH=restored_search_path(), GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="",
                       GCM_INTERACTIVE="never", GCM_GUI_PROMPT="false")
    return environment


def scope(payload, directory, deadline):
    root, remote, url, updates_path, endpoint_path = payload.decode().split("\0")[:-1]
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", url):
        raise ValueError("unsupported destination")
    if any((key.startswith(("GIT_CONFIG_", "GIT_SSL", "GIT_PROXY")) and key != "GIT_CONFIG_NOSYSTEM") or key in
           ("GIT_NAMESPACE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR") for key in os.environ):
        raise ValueError("unproved transport environment")
    updates = Path(updates_path).read_bytes()
    if len(updates) > EVIDENCE_LIMIT or len(updates.splitlines()) != 1 or not updates.endswith(b"\n"):
        raise ValueError("mixed push")
    local_ref, new, remote_ref, old = updates.decode().split()
    if (not all(ref.startswith("refs/heads/") for ref in (local_ref, remote_ref))
            or not all(re.fullmatch("[0-9a-f]{40}", oid) and set(oid) != {"0"} for oid in (old, new))):
        raise ValueError("unsupported update")
    environment = proof_environment()
    git_binary = local_tool("git", environment)
    if "GIT_EXEC_PATH" in os.environ:
        default = execute([git_binary, "--exec-path"], environment, deadline, maximum=65536)
        if default != os.fsencode(os.environ["GIT_EXEC_PATH"]) + b"\n":
            raise ValueError("custom Git helper directory")

    def consumer(*args, data=b""):
        return execute([git_binary, "-C", root, *args], environment, deadline, data=data)

    keys = consumer("config", "--name-only", "--list").decode().lower().splitlines()
    if any((key.startswith("http.") and key != "http.version") or key.startswith("url.")
           or re.fullmatch(r"remote\..*\.(receivepack|uploadpack|vcs|proxy|pushurl)", key) for key in keys):
        raise ValueError("unproved transport configuration")
    if "http.version" in keys:
        versions = consumer("config", "--null", "--get-all", "http.version").split(b"\0")[:-1]
        if not versions or any(value not in (b"HTTP/1.1", b"HTTP/2") for value in versions):
            raise ValueError("unsupported HTTP version")
    if consumer("rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ValueError("shallow history")
    object_dir = consumer("rev-parse", "--path-format=absolute", "--git-path", "objects").decode().strip()
    if any(c in object_dir for c in ("\n", "\0")):
        raise ValueError("object store path")
    clean = dict(environment, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                 GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1", GIT_ATTR_NOSYSTEM="1")
    history = directory / "proof.git"
    execute([git_binary, "init", "--bare", "--object-format=sha1", str(history)], clean, deadline)
    clean["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = object_dir

    def git(*args, maximum=EVIDENCE_LIMIT):
        return execute([git_binary, "--no-pager", "--literal-pathspecs", "-c", "core.commitGraph=false",
                        "-c", "core.attributesFile=" + os.devnull, "--git-dir=" + str(history), *args],
                       clean, deadline, maximum)

    first, second = git("show", "-s", "--format=%P", new).decode().split()
    commits, cursor = [], first
    while cursor != old:
        if len(commits) == 128:
            raise ValueError("commit walk bound")
        parents = git("show", "-s", "--format=%P", cursor).decode().split()
        if len(parents) != 1:
            raise ValueError("nonlinear unpublished history")
        commits.append(cursor)
        cursor = parents[0]
    bases = git("merge-base", "--all", first, second).decode().split()
    if len(bases) != 1:
        raise ValueError("ambiguous base")
    credentials = consumer("-c", "credential.interactive=false", "-c", "core.askPass=", "credential", "fill",
                           data=("url=" + url + "\n\n").encode())
    fields = dict(line.split(b"=", 1) for line in credentials.splitlines() if b"=" in line)
    username, password = fields[b"username"], fields[b"password"]
    if not username or not password or b":" in username:
        raise ValueError("unavailable authentication")
    authorization = b"Basic " + base64.b64encode(username + b":" + password)
    response = execute([local_tool("curl", environment), "-q", "--silent", "--show-error", "--fail", "--include",
                        "--suppress-connect-headers", "--proto", "=https", "--max-redirs", "0",
                        "--max-time", str(max(0.001, deadline - time.monotonic())), "--config", "-",
                        "--url", url + "/info/refs?service=git-receive-pack"], environment, deadline,
                       data=b'header = "Authorization: ' + authorization + b'"\n')
    refs = advertisement(response)
    if refs.get(remote_ref.encode()) != old:
        raise ValueError("old receiving ref mismatch")
    published = refs[b"refs/heads/main"]
    git("merge-base", "--is-ancestor", second, published)
    trees = read_trees(git, (bases[0], first, second, new))
    selected = list(select_entries(*trees))
    endpoint = Path(endpoint_path).read_bytes()
    if len(endpoint) > TREE_LIMIT:
        raise ValueError("endpoint bound")
    output = bytearray(b"## ref-update " + updates)
    output.extend(("endpoint_sha256 " + hashlib.sha256(endpoint).hexdigest() + "\n").encode())
    output.extend((f"published-main {published}; merge-parents {first} {second}; base {bases[0]}\n").encode())
    output.extend(b"\n".join(line for line in endpoint.splitlines() if line.startswith(b"commit-subject ")) + b"\n")
    output.extend(b"## Complete endpoint paths\n" + git("diff", "--name-status", "--no-renames", old, new))
    for path, reason, entries in selected:
        output.extend(("selected-entry " + json.dumps({"path": os.fsdecode(path), "reason": reason,
                       "base_first_second_result": entries}, ensure_ascii=True) + "\n").encode())
        if len(output) > EVIDENCE_LIMIT:
            raise ValueError("evidence bound")
    for commit in reversed(commits):
        output.extend(git("show", "--format=commit-subject %H %s", "--no-ext-diff", "--no-textconv", "--no-renames", commit))
        if len(output) > EVIDENCE_LIMIT:
            raise ValueError("evidence bound")
    if selected:
        paths = [os.fsdecode(path) for path, _, _ in selected]
        for parent in (first, second):
            output.extend(git("diff", "--no-ext-diff", "--no-textconv", "--no-renames", parent, new, "--", *paths))
            if len(output) > EVIDENCE_LIMIT:
                raise ValueError("evidence bound")
    if len(output) > EVIDENCE_LIMIT:
        raise ValueError("evidence bound")
    return output


def main():
    deadline = time.monotonic() + 10
    payload = sys.stdin.buffer.read(65537)
    if len(payload) > 65536 or len(payload.split(b"\0")) != 6 or not payload.endswith(b"\0"):
        raise ValueError("invalid push metadata")
    environment = dict(os.environ, PATH=restored_search_path())
    bash_binary = local_tool("bash", environment)
    if len(sys.argv) == 4 and sys.argv[1] in ("worker", "publish-worker"):
        directory, deadline = Path(sys.argv[2]), float(sys.argv[3])
        output = scope(payload, directory, deadline)
        if sys.argv[1] == "worker":
            sys.stdout.buffer.write(output)
            return
        staged = directory / "scoped.diff"
        staged.write_bytes(output)
        staged.chmod(0o600)
        # The shared renderer and its descendants stay inside the proof's lifetime.
        renderer = '''set -euo pipefail
tooling_root="$1"
source "$tooling_root/.agents/lib/subagent.sh"
source "$tooling_root/.agents/lib/commit-push-evidence.sh"
commit_push_render_evidence "$2"
'''
        execute([bash_binary, "-c", renderer, "push-merge-render", str(PLUGIN), str(staged)],
                proof_environment(), deadline)
        if time.monotonic() >= deadline:
            raise ValueError("publication deadline")
        # Staging shares the endpoint filesystem; replacement is the commit point.
        os.replace(staged, payload.decode().split("\0")[4])
        return
    if sys.argv[1:] not in ([], ["--publish"]):
        raise ValueError("invalid helper operation")
    publish = sys.argv[1:] == ["--publish"]
    spec = importlib.util.spec_from_file_location("push_lifetime", PLUGIN / "scripts/design-worker-process.py")
    processes = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(processes)
    endpoint = Path(payload.decode().split("\0")[4])
    with tempfile.TemporaryDirectory(prefix="push-merge-proof-", dir=endpoint.parent) as temporary:
        directory = Path(temporary)
        owner = processes.Owner(directory, uuid.uuid4().hex, str(Path(sys.executable).resolve()),
                                bash_binary, PLUGIN / ".agents/hooks/design-worker-group.sh")
        try:
            output = execute([sys.executable, "-I", str(Path(__file__).resolve()),
                              "publish-worker" if publish else "worker", str(directory), str(deadline)],
                             environment, deadline, data=payload, owner=owner)
        finally:
            owner.close()
        sys.stdout.buffer.write(output)


if __name__ == "__main__":
    for event in (signal.SIGTERM, signal.SIGINT, getattr(signal, "SIGHUP", signal.SIGTERM)):
        signal.signal(event, lambda *_: (_ for _ in ()).throw(InterruptedError()))
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, InterruptedError):
        sys.exit(1)  # Optional proof failures retain the caller's untouched endpoint snapshot.
