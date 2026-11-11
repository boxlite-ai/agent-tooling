#!/usr/bin/env python3
"""Trusted fixture CLI: the real hook owns its stdin, broker process, and stdout."""
import json
from pathlib import Path
import re
import subprocess
import sys
import os
import time

directory = Path(__file__).resolve().parent
if "--version" in sys.argv:
    print("codex-cli 0.162.1; Claude Code 2.1.322")
    sys.exit(0)
task = sys.stdin.read()
mode = (directory / "mode").read_text() if (directory / "mode").exists() else "normal"
(directory / "observed").write_text(mode)
(directory / "worker.pid").write_text(str(os.getpid()))
data = json.JSONDecoder().raw_decode(task.split("UNTRUSTED_TASK_INPUT_JSON:\n", 1)[1])[0]
(directory / "task.txt").write_text(task)
(directory / "task-input.json").write_text(json.dumps(data))
codex = "exec" in sys.argv
if codex:
    cli = next(json.loads(value.split("=", 1)[1]) for value in sys.argv if value.startswith("mcp_servers.probe.command="))
    args = next(json.loads(value.split("=", 1)[1]) for value in sys.argv if value.startswith("mcp_servers.probe.args="))
else:
    mcp = json.loads(Path(sys.argv[sys.argv.index("--mcp-config") + 1]).read_text())["mcpServers"]["probe"]
    cli, args = mcp["command"], mcp["args"]
broker = subprocess.Popen([cli, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
(directory / "broker.pid").write_text(str(broker.pid))


def call(number, method, params):
    broker.stdin.write(json.dumps({"jsonrpc": "2.0", "id": number, "method": method, "params": params}) + "\n")
    broker.stdin.flush()
    line = broker.stdout.readline()
    if not line:
        raise ValueError("broker exited: " + broker.stderr.read(4000))
    response = json.loads(line)
    if "error" in response:
        raise ValueError("broker rejected fixture request")
    return response["result"]


call(1, "initialize", {})
call(2, "tools/call", {"name": "research_list", "arguments": {}})
if mode == "hang":
    (directory / "ready").write_text("ready")
    time.sleep(120)
if mode in ("late", "long"):
    time.sleep(1.3 if mode == "late" else 901)
    broker.stdin.write(json.dumps({"jsonrpc":"2.0","id":3,"method":"tools/call",
        "params":{"name":"source_list","arguments":{"prefix":""}}}) + "\n")
    broker.stdin.flush()
    assert "error" in json.loads(broker.stdout.readline())
else:
    listed = call(3, "tools/call", {"name": "source_list", "arguments": {"prefix": ""}})
    paths = json.loads(listed["content"][0]["text"])
    assert "untracked-secret" not in paths
    if "source.txt" in paths:
        read = call(4, "tools/call", {"name": "source_read", "arguments": {"path": "source.txt", "version": "current"}})
        assert "tracked evidence" in read["content"][0]["text"]
if mode == "pause":
    (directory / "ready").write_text("ready")
    until = time.monotonic() + 15
    while not (directory / "release").exists() and time.monotonic() < until:
        time.sleep(0.02)
broker.stdin.close()
broker.wait(timeout=5)
role = "advisor" if "verdict" in data else "auditor"
queued = directory / "result.json"
result = json.loads(queued.read_text()) if queued.exists() else ({"content_sha256": data["content_sha256"], "advice": []}
    if role == "advisor" else {"content_sha256": data["content_sha256"], "verdict": "PASS", "findings": [], "advisories": []})
if mode == "invalid":
    print("invalid completion")
    sys.exit(0)
if mode == "nonzero":
    sys.exit(9)
if mode == "wrong-digest":
    result["content_sha256"] = "0" * 64
if mode == "wrong-role":
    result = {"content_sha256": data["content_sha256"], "advice": []}
if mode in ("late", "long"):
    result["advisories"] = ["low: unchecked: research cutoff reached; remaining source checks are unverified"]
if mode == "change-document":
    document = json.loads((directory / "document.json").read_text())
    document["body"] += "\nChanged while reviewing."
    (directory / "document.json").write_text(json.dumps(document))
if mode == "oversized":
    print("x" * 1048577)
    sys.exit(0)
if codex:
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(result)}}))
else:
    print(json.dumps({"is_error": False, "structured_output": result}))
