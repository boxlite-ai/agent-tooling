"""Read specification snapshots and native oasdiff reports; no persistent writes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

SPEC_PATHSPEC = ":(top,glob)**/*openapi*.yaml"
OASDIFF_VERSION = "1.33.0"
SKIP_CONFIRMATION = "api compatibility: skip"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def normalize_line_endings(content):
    return content.replace(b"\r\n", b"\n") if content is not None else None


def run(args, root, *, accepted=(0,), env=None):
    result = subprocess.run(args, cwd=root, env=env, capture_output=True, timeout=60)
    if result.returncode not in accepted:
        raise ValueError(f"{args[0]} failed ({result.returncode}): {result.stderr.decode(errors='replace')[:1000]}")
    return result.stdout


def git(root, *args):
    return run(["git", *args], root)


def spec_revision(root, revision, path):
    """Return the specification at a revision ("" is the index), or None when absent."""
    result = subprocess.run(["git", "show", f"{revision}:{path}"], cwd=root, capture_output=True)
    return result.stdout if result.returncode == 0 else None


def specification_paths(root, revision=None):
    if revision:
        names = git(root, "ls-tree", "-r", "-z", "--name-only", revision)
    else:
        names = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", SPEC_PATHSPEC)
    return {os.fsdecode(name) for name in names.split(b"\0") if name
            and "openapi" in Path(os.fsdecode(name)).name and name.endswith(b".yaml")}


def load_inputs(root, explicit_base, revision=None):
    """Read changed specifications at the merge base and commit or working copy."""
    base_ref = explicit_base
    if not base_ref:
        for ref in ("origin/main", "main"):
            if subprocess.run(["git", "rev-parse", "--verify", ref], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                base_ref = ref
                break
    if not base_ref or base_ref.startswith("-"):
        raise ValueError("pass --base to identify the pre-change revision")
    base = git(root, "merge-base", revision or "HEAD", base_ref).decode().strip()
    specifications = []
    for name in sorted(specification_paths(root, base) | specification_paths(root, revision)):
        before = spec_revision(root, base, name)
        if revision:
            after = spec_revision(root, revision, name)
        else:
            path = root / name
            if path.is_symlink():
                raise ValueError(f"{name} must be a regular file")
            after = path.read_bytes() if path.is_file() else None
        if normalize_line_endings(before) == normalize_line_endings(after):
            if not revision:
                staged = spec_revision(root, "", name)
                if staged is not None and normalize_line_endings(staged) != normalize_line_endings(after):
                    raise ValueError(f"{name}: staged OpenAPI differs from the working copy; audit the intended changes")
            continue
        if before is None or after is None:
            raise ValueError(f"{name}: adding or deleting a complete OpenAPI contract requires manual review")
        specifications.append({"path": name, "before": before, "after": after})
    if not specifications:
        return None
    tooling = Path(__file__).resolve().parents[2]
    policy = {p: hashlib.sha256((tooling / p).read_bytes()).hexdigest() for p in (
        ".agents/lib/api_contract.py", "scripts/api-compatibility.py", "scripts/api-compatibility.sh")}
    # Confirmation binds the specification change, so unrelated files never invalidate it.
    # Ignore Git's CRLF/LF conversion in approval hashes; retain exact snapshots.
    fingerprint = digest({
        "specifications": [{"path": spec["path"], **{
            side: hashlib.sha256(normalize_line_endings(spec[side])).hexdigest()
            for side in ("before", "after")}} for spec in specifications],
        "policy": policy, "oasdiff": OASDIFF_VERSION,
    })
    return {"base": base, "specifications": specifications, "fingerprint": fingerprint}


def inspect_specs(root, before, after, *, details=False):
    executable = os.environ.get("OASDIFF_BIN", "oasdiff")
    env = {k: v for k, v in os.environ.items() if not k.startswith("OASDIFF_")}
    version = run([executable, "--version"], root, env=env).decode().strip()
    if version != f"oasdiff version {OASDIFF_VERSION}":
        raise ValueError(f"requires oasdiff {OASDIFF_VERSION}; found {version}")
    with tempfile.TemporaryDirectory(prefix="api-contract-") as directory:
        work = Path(directory)
        for name, content in (("before.yaml", before), ("after.yaml", after), ("config.json", b"{}")):
            (work / name).write_bytes(content)

        def invoke(action, *paths):
            args = [executable, action, *paths, "--config", str(work / "config.json"),
                    "--allow-external-refs=false", "--format", "json"]
            return json.loads(run(args, work, accepted=(0, 1) if action == "breaking" else (0,), env=env))

        changes = invoke("changelog", "before.yaml", "after.yaml")
        breaking = invoke("breaking", "before.yaml", "after.yaml")
        if not isinstance(changes, list) or not isinstance(breaking, list):
            raise ValueError("invalid oasdiff findings")
        detail = invoke("diff", "before.yaml", "after.yaml") if details else None
        if detail is not None and not isinstance(detail, dict):
            raise ValueError("invalid oasdiff diff")
        return invoke("flatten", "before.yaml"), invoke("flatten", "after.yaml"), changes, breaking, detail


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
