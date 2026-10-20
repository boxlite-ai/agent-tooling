"""Execute one SDK adapter against isolated sources and capture real HTTP traffic."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tarfile
import threading
from urllib.parse import parse_qs, urlsplit

from api_contract import canonical, git, link_target


def snapshots(root, inputs, directory):
    before, after = directory / "before", directory / "after"
    before.mkdir()
    after.mkdir()
    archive = git(root, "archive", inputs["base"])
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for entry in source:
            destination = before / entry.name
            if not destination.resolve().is_relative_to(before.resolve()):
                raise ValueError("source archive escapes snapshot")
            if entry.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.extractfile(entry).read())
                destination.chmod(entry.mode & 0o777)
            elif entry.issym():
                destination.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(link_target(entry.name, entry.linkname), destination)
            else:
                raise ValueError(f"unsupported source archive entry: {entry.name}")
    for name, data in inputs["files"].items():
        destination = after / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod((root / name).stat().st_mode & 0o777)
    for name, target in inputs["links"].items():
        destination = after / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, destination)
    return before, after


def capture(adapter, sdk_root, current, feature, declaration, case, timeout):
    response = declaration.get("response")
    if not isinstance(response, dict) or type(response.get("status")) is not int:
        raise ValueError(f"declare a stub response status/body for {feature['id']}")
    requests, errors = [], []
    ignored = {"host", "content-length", "connection"}

    class Recorder(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def record(self):
            try:
                self.connection.settimeout(5)
                if self.headers.get("Transfer-Encoding"):
                    raise ValueError("chunked requests require a consumer-specific test")
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 8 * 1024 * 1024:
                    raise ValueError("request exceeds capture limit")
                raw = self.rfile.read(length)
                if len(raw) != length:
                    raise ValueError("incomplete request body")
                body = {"raw": base64.b64encode(raw).decode()}
                if raw and "json" in self.headers.get("Content-Type", ""):
                    body = {"json": json.loads(raw)}
                requests.append({"method": self.command, "path": self.path,
                                 "headers": sorted((k.lower(), v) for k, v in self.headers.items() if k.lower() not in ignored),
                                 "body": body})
                payload = canonical(response.get("body")).encode()
                self.send_response(response["status"])
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except (ValueError, OSError) as error:
                errors.append(str(error))

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = record

    server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
    thread.start()
    values = {"default": feature["schema"].get("default"), "null": None,
              "non-default": declaration["nonDefault"]}
    context = {"operation": feature["method"] + " " + feature["path"],
               "field": feature["field"], "case": case}
    if case != "omitted":
        context["value"] = values[case]
    env = dict(os.environ, API_COMPAT_SDK_ROOT=str(sdk_root),
               API_COMPAT_URL=f"http://127.0.0.1:{server.server_port}", API_COMPAT_INPUT=canonical(context))
    try:
        # Output stays outside the request comparison and never becomes evidence.
        with (current.parent / "adapter.log").open("wb") as log:
            process = subprocess.Popen(adapter, cwd=current, env=env, stdout=log, stderr=log,
                                       start_new_session=os.name != "nt")
            try:
                result = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise ValueError(f"adapter timed out: {feature['id']} {case}")
        if result:
            raise ValueError(f"adapter exited {result}: {feature['id']} {case}")
        if errors or not requests:
            raise ValueError(f"capture failed for {feature['id']} {case}: {errors or 'no HTTP request'}")
        return requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def field_value(request, field):
    location, name = field.split("/", 1)
    if location == "body":
        value = request["body"]["json"]
        for token in name.split("/"):
            value = value[token.replace("~1", "/").replace("~0", "~")]
        return value
    if location == "query":
        return parse_qs(urlsplit(request["path"]).query, keep_blank_values=True)[name]
    if location == "header":
        return [v for k, v in request["headers"] if k == name.lower()]
    raise ValueError(f"unsupported request field location: {location}")


def compare_case(old, new, feature, declaration, case):
    equivalent = case in ("omitted", "default") or (case == "null" and declaration["nullIsOmitted"])
    if equivalent:
        if canonical(old) != canonical(new):
            raise ValueError(f"request differs from pre-change SDK: {feature['id']} {case}")
        return
    expected = declaration["nonDefault"] if case == "non-default" else None
    if not feature["field"].startswith("body/"):
        expected = [expected if isinstance(expected, str) else canonical(expected)]
    matches = []
    request_path = declaration.get("requestPath", feature["path"])
    pattern = "".join("[^/]+" if part.startswith("{") else re.escape(part)
                      for part in re.split(r"(\{[^{}]+\})", request_path))
    for request in new:
        if request["method"] != feature["method"] or not re.fullmatch(pattern, urlsplit(request["path"]).path):
            continue
        try:
            matches.append(canonical(field_value(request, feature["field"])) == canonical(expected))
        except (KeyError, TypeError):
            continue
    if not any(matches):
        raise ValueError(f"requested value missing from HTTP request: {feature['id']} {case}")


def execute(root, inputs, requirements, directory):
    before, current = snapshots(root, inputs, directory)
    passed = []
    timeout = inputs["config"].get("timeoutSeconds", 120)
    if type(timeout) is not int or not 1 <= timeout <= 600:
        raise ValueError("timeoutSeconds must be between 1 and 600")
    for requirement in requirements:
        sdk, feature, declaration = (requirement[key] for key in ("sdk", "feature", "declaration"))
        old = capture(sdk["command"], before, current, feature, declaration, "omitted", timeout)
        for case in requirement["cases"]:
            new = capture(sdk["command"], current, current, feature, declaration, case, timeout)
            compare_case(old, new, feature, declaration, case)
            passed.append(f"{sdk['name']} {feature['id']} {case}")
    return passed
