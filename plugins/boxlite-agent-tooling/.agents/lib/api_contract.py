"""Read specification snapshots and native oasdiff reports; no persistent writes."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

SPEC_PATHSPEC = ":(top,glob)**/*openapi*.yaml"
OASDIFF_VERSION = "1.33.0"
SIDES = ("before", "after")
REGULAR_MODES = (b"100644", b"100755")
OFFLINE_GIT = dict(GIT_NO_LAZY_FETCH="1", GIT_ALLOW_PROTOCOL="", GIT_NO_REPLACE_OBJECTS="1")
REFERENCE_REFUSAL = re.compile(
    r'^Error: failed to load (?:base spec from "before\.yaml"|revision spec from "after\.yaml"): '
    r'encountered disallowed external reference: "[^\r\n]+"$', re.MULTILINE
)


class ToolError(ValueError):
    def __init__(self, result):
        self.status = result.returncode
        self.stderr = result.stderr.decode(errors="replace")
        super().__init__(f"{result.args[0]} failed ({self.status}): {self.stderr[:1000]}")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def normalize_line_endings(content):
    return content.replace(b"\r\n", b"\n") if content is not None else None


def run(args, root, *, accepted=(0,), env=None, input=None):
    timeout = 60
    deadline = os.environ.get("BOXLITE_API_EVIDENCE_DEADLINE")
    if deadline:
        timeout = min(timeout, int(deadline) - time.time())
        if timeout <= 0:
            raise ValueError("OpenAPI audit evidence preparation exceeded its deadline")
    result = subprocess.run(args, cwd=root, env=env, input=input, capture_output=True, timeout=timeout)
    if result.returncode not in accepted:
        raise ToolError(result)
    return result.stdout


def git(root, *args):
    return run(["git", *args], root, env=dict(os.environ, **OFFLINE_GIT))


def contract_entries(root, revision):
    if revision is not None:
        listing = git(root, "ls-tree", "-r", "-z", "--full-tree", revision)
    else:
        listing = git(root, "ls-files", "--stage", "-z", "--", SPEC_PATHSPEC)
    entries = {}
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b"\t", 1)
        path = os.fsdecode(path_bytes)
        if "openapi" not in path.rsplit("/", 1)[-1] or not path.endswith(".yaml"):
            continue
        mode, middle, last = metadata.split()
        if mode == b"160000":
            continue
        if revision is None and last != b"0":
            raise ValueError(f"{path}: resolve OpenAPI index conflicts before auditing")
        entries[path] = (mode, (last if revision else middle).decode("ascii"))
    return entries


def contract_blob(root, entry, path, side):
    if entry is None:
        return None
    mode, oid = entry
    if mode not in REGULAR_MODES:
        raise ValueError(f"{path}: {side} OpenAPI input must be a regular file")
    try:
        return git(root, "cat-file", "blob", oid)
    except ToolError as error:
        raise ValueError(f"{path}: unavailable {side} OpenAPI blob {oid}") from error


def resolve_base(root, explicit_base, head):
    base_ref = explicit_base
    if not base_ref:
        for ref in ("origin/main", "main"):
            try:
                git(root, "rev-parse", "--verify", ref)
            except ToolError:
                continue
            else:
                base_ref = ref
                break
    if not base_ref or base_ref.startswith("-"):
        raise ValueError("pass --base to identify the pre-change revision")
    return git(root, "merge-base", head, base_ref).decode().strip()


def load_inputs(root, base, candidate, *, stage_required=False):
    """Capture the comparison once, including eligible files shared by its roots."""
    before_entries = contract_entries(root, base)
    after_entries = contract_entries(root, candidate)
    names = before_entries.keys() | after_entries.keys()
    if candidate is None:
        untracked = git(root, "ls-files", "-z", "--others", "--exclude-standard", "--", SPEC_PATHSPEC)
        names.update(os.fsdecode(name) for name in untracked.split(b"\0") if name)
    snapshots = {side: {} for side in SIDES}
    specifications = []
    for name in sorted(names):
        before_entry = before_entries.get(name)
        after_entry = after_entries.get(name)
        if (candidate is not None and before_entry == after_entry
                and before_entry and before_entry[0] == b"120000"):
            continue
        before = contract_blob(root, before_entry, name, "base")
        if candidate is not None:
            after = contract_blob(root, after_entry, name, "candidate")
        else:
            path = root / name
            if path.resolve() != path:
                raise ValueError(f"{name} must be a regular file")
            after = path.read_bytes() if path.is_file() else None
        if before is not None:
            snapshots["before"][name] = before
        if after is not None and after_entry and after_entry[0] in REGULAR_MODES:
            snapshots["after"][name] = after
        unchanged = normalize_line_endings(before) == normalize_line_endings(after)
        if candidate is None and (stage_required or unchanged):
            staged = contract_blob(root, after_entry, name, "staged")
            if normalize_line_endings(staged) != normalize_line_endings(after):
                if unchanged and (staged is not None or stage_required):
                    raise ValueError(f"{name}: staged OpenAPI differs from the working copy; audit the intended changes")
                if stage_required and after is not None and before is not None:
                    raise ValueError(f"{name}: stage the reviewed OpenAPI before committing")
        if unchanged:
            continue
        if before is None or after is None:
            raise ValueError(f"{name}: adding or deleting a complete OpenAPI contract requires manual review")
        specifications.append({"path": name, "before": before, "after": after})
    return specifications, snapshots


def input_fingerprint(specifications, reference_inputs):
    tooling = Path(__file__).resolve().parents[2]
    policy = {p: hashlib.sha256((tooling / p).read_bytes()).hexdigest() for p in (
        ".agents/lib/api_contract.py", "scripts/api-compatibility.py", "scripts/api-compatibility.sh",
        ".agents/lib/api-question.json", ".agents/lib/user-question.sh")}
    # Confirmation binds the specification change, so unrelated files never invalidate it.
    # Ignore Git's CRLF/LF conversion in approval hashes; retain exact snapshots.
    inputs = {
        "specifications": [{"path": spec["path"], **{
            side: hashlib.sha256(normalize_line_endings(spec[side])).hexdigest()
            for side in SIDES}} for spec in specifications],
        "policy": policy, "oasdiff": OASDIFF_VERSION,
    }
    if reference_inputs:
        inputs["references"] = reference_inputs
    return digest(inputs)


def private_git(work, env):
    work.mkdir(mode=0o700)
    env = {key: value for key, value in env.items() if not key.startswith("GIT_")}
    env.update(OFFLINE_GIT, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    env["GIT_INDEX_FILE"] = str(work / "index")
    run(["git", "init", "--bare", "--quiet", "--template="], work, env=env)
    return env


def write_tree(work, env, documents):
    run(["git", "read-tree", "--empty"], work, env=env)
    entries = []
    for path, content in sorted(documents.items()):
        oid = run(["git", "hash-object", "-w", "--stdin"], work, env=env, input=content).strip()
        entries.append(b"100644 " + oid + b"\t" + os.fsencode(path) + b"\0")
    run(["git", "update-index", "-z", "--index-info"], work, env=env, input=b"".join(entries))
    return run(["git", "write-tree"], work, env=env).decode().strip()


def resolved_paths(trace, tree, name, documents):
    starts = {}
    successful = set()
    for line in trace.read_bytes().splitlines():
        event = json.loads(line)
        args = event.get("argv", [])
        if event.get("event") == "start" and args[1:2] == ["show"]:
            if len(args) != 4 or args[2] != "--end-of-options" or not args[3].startswith(tree + ":"):
                raise ValueError(f"{name}: unexpected Git read during OpenAPI reference discovery")
            path = args[3].split(":", 1)[1]
            if path not in documents:
                raise ValueError(f"{name}: OpenAPI reference read outside its snapshot")
            starts[event["sid"]] = path
        elif event.get("event") == "exit" and event["sid"] in starts and event.get("code") == 0:
            successful.add(event["sid"])
    if set(starts) != successful or name not in starts.values():
        raise ValueError(f"{name}: incomplete OpenAPI reference discovery")
    return {path: documents[path] for path in set(starts.values())}


class ReferenceDiscovery:
    def __init__(self, directory, snapshots):
        self.root = directory / "discovery.git"
        self.snapshots = snapshots
        self.store = None

    def resolve(self, name, work, env, invoke):
        for side in SIDES:
            if name not in self.snapshots[side]:
                raise ValueError(f"{name}: {side} OpenAPI root is not a regular tracked file")
        if self.store is None:
            discovery_env = private_git(self.root, env)
            trees = {side: write_tree(self.root, discovery_env, self.snapshots[side]) for side in SIDES}
            self.store = discovery_env, trees
        discovery_env, trees = self.store
        references = {}
        for side in SIDES:
            tree = trees[side]
            trace = work / (side + ".jsonl")
            invoke("flatten", [f"{tree}:{name}"], self.root,
                   dict(discovery_env, GIT_TRACE2_EVENT=str(trace)))
            references[side] = resolved_paths(trace, tree, name, self.snapshots[side])
        return references


def inspect_specs(root, specification, discovery, *, details=False, scratch=None):
    executable = os.environ.get("OASDIFF_BIN", "oasdiff")
    env = {k: v for k, v in os.environ.items() if not k.startswith("OASDIFF_")}
    version = run([executable, "--version"], root, env=env).decode().strip()
    if version != f"oasdiff version {OASDIFF_VERSION}":
        raise ValueError(f"requires oasdiff {OASDIFF_VERSION}; found {version}")
    with tempfile.TemporaryDirectory(prefix="api-contract-", dir=scratch) as directory:
        work = Path(directory)
        name = specification["path"]
        paths = {side: side + ".yaml" for side in SIDES}
        for side in SIDES:
            (work / paths[side]).write_bytes(specification[side])
        (work / "config.json").write_bytes(b"{}")

        def invoke(action, names, cwd, invocation_env):
            args = [executable, action, *names, "--config", str(work / "config.json"),
                    "--allow-external-refs=false", "--format", "json"]
            accepted = (0, 1) if action == "breaking" else (0,)
            return json.loads(run(args, cwd, accepted=accepted, env=invocation_env))

        cwd = work
        references = {}
        try:
            changes = invoke("changelog", paths.values(), cwd, env)
        except ToolError as error:
            if error.status != 102 or not REFERENCE_REFUSAL.search(error.stderr):
                raise
            references = discovery.resolve(name, work, env, invoke)
            cwd = work / "replay.git"
            env = private_git(cwd, env)
            paths = {side: f"{write_tree(cwd, env, references[side])}:{name}" for side in SIDES}
            changes = invoke("changelog", paths.values(), cwd, env)
        breaking = invoke("breaking", paths.values(), cwd, env)
        if not isinstance(changes, list) or not isinstance(breaking, list):
            raise ValueError("invalid oasdiff findings")
        detail = invoke("diff", paths.values(), cwd, env) if details else None
        if detail is not None and not isinstance(detail, dict):
            raise ValueError("invalid oasdiff diff")
        flattened = [invoke("flatten", [paths[side]], cwd, env) for side in SIDES]
        if any(not isinstance(document, dict) or not document.get("openapi") for document in flattened):
            raise ValueError(f"{name}: comparing a schema-only OpenAPI root requires manual review")
        return flattened, changes, breaking, detail, paths, references


def default_changes(before, after, path="", mapping=False):
    changes = []
    if isinstance(before, dict) and isinstance(after, dict):
        if not mapping and ("default" in before or "default" in after) and canonical(before.get("default")) != canonical(after.get("default")):
            changes.append(path + "/default")
        elif not mapping and ("default" in before) != ("default" in after):
            changes.append(path + "/default")
        for key in before.keys() & after.keys():
            if not mapping and (key in {"default", "example", "examples", "description", "summary"} or key.startswith("x-")):
                continue
            is_mapping = not mapping and key in {"properties", "schemas", "responses", "content", "headers", "paths", "variables", "securitySchemes"}
            changes.extend(default_changes(before[key], after[key], path + "/" + key, is_mapping))
    elif isinstance(before, list) and isinstance(after, list):
        if path.endswith("/parameters"):
            # Parameter order has no meaning; oasdiff compares their identities.
            return changes
        for index, (left, right) in enumerate(zip(before, after)):
            changes.extend(default_changes(left, right, f"{path}/{index}"))
    return changes
