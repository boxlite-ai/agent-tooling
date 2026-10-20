"""Read immutable inputs and derive API review obligations; no state writes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

SPEC = "openapi/box.openapi.yaml"
OASDIFF_VERSION = "1.33.0"
METHODS = {"get", "put", "post", "delete", "patch", "head", "options", "trace"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def run(args, root, *, accepted=(0,), env=None):
    result = subprocess.run(args, cwd=root, env=env, capture_output=True, timeout=60)
    if result.returncode not in accepted:
        raise ValueError(f"{args[0]} failed ({result.returncode}): {result.stderr.decode(errors='replace')[:1000]}")
    return result.stdout


def git(root, *args):
    return run(["git", *args], root)


def spec_revision(root, revision):
    """Return the specification at a revision ("" is the index), or None when absent."""
    result = subprocess.run(["git", "show", f"{revision}:{SPEC}"], cwd=root, capture_output=True)
    return result.stdout if result.returncode == 0 else None


def load_inputs(root, explicit_base):
    """Read only the Box API specification: its merge-base and working copies."""
    base_ref = explicit_base
    if not base_ref:
        for ref in ("origin/main", "main"):
            if subprocess.run(["git", "rev-parse", "--verify", ref], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                base_ref = ref
                break
    if not base_ref or base_ref.startswith("-"):
        raise ValueError("pass --base to identify the pre-change revision")
    base = git(root, "merge-base", "HEAD", base_ref).decode().strip()
    before = spec_revision(root, base)
    path = root / SPEC
    if path.is_symlink():
        raise ValueError(f"{SPEC} must be a regular file")
    after = path.read_bytes() if path.is_file() else None
    if before == after:
        staged = spec_revision(root, "")
        if staged is not None and staged != after:
            raise ValueError("staged OpenAPI differs from the working copy; audit the intended changes")
        return None
    if before is None or after is None:
        raise ValueError("adding or deleting the complete Box API contract requires manual review")
    tooling = Path(__file__).resolve().parents[2]
    policy = {p: hashlib.sha256((tooling / p).read_bytes()).hexdigest() for p in (
        ".agents/lib/api_contract.py", "scripts/api-compatibility.py", "scripts/api-compatibility.sh")}
    # Confirmation binds the specification change, so unrelated files never invalidate it.
    fingerprint = digest({"before": hashlib.sha256(before).hexdigest(), "after": hashlib.sha256(after).hexdigest(),
                          "policy": policy, "oasdiff": OASDIFF_VERSION})
    return {"base": base, "before": before, "after": after, "fingerprint": fingerprint}


def inspect_specs(root, before, after):
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
        return invoke("flatten", "before.yaml"), invoke("flatten", "after.yaml"), changes, breaking


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


def resolve(spec, node):
    seen = set()
    while isinstance(node, dict) and "$ref" in node:
        reference = node["$ref"]
        if not isinstance(reference, str) or not reference.startswith("#/") or reference in seen:
            raise ValueError(f"unsupported reference: {reference}")
        seen.add(reference)
        target = spec
        for token in reference[2:].split("/"):
            target = target[token.replace("~1", "/").replace("~0", "~")]
        node = {**target, **{k: v for k, v in node.items() if k != "$ref"}}
    return node


def request_fields(spec, operation, path_item):
    fields = {}

    def properties(node, prefix, visited):
        reference = node.get("$ref")
        if reference and reference in visited:
            return
        node = resolve(spec, node)
        visited = visited | {reference} if reference else visited
        for name, child in node.get("properties", {}).items():
            location = prefix + "/" + name.replace("~", "~0").replace("/", "~1")
            schema = resolve(spec, child)
            fields[location] = {"schema": schema, "required": name in node.get("required", [])}
            properties(child, location, visited)
        # Array/union changes still appear in changelog; unmapped additions fail closed below.

    body = resolve(spec, operation.get("requestBody", {}))
    for media, content in body.get("content", {}).items():
        if media == "application/json":
            properties(content.get("schema", {}), "body", set())
    for parameter in path_item.get("parameters", []) + operation.get("parameters", []):
        parameter = resolve(spec, parameter)
        fields[parameter["in"] + "/" + parameter["name"]] = {
            "schema": resolve(spec, parameter.get("schema", {})), "required": parameter.get("required", False)}
    return fields


def allows_null(spec, schema, depth=0):
    if depth > 30:
        raise ValueError("recursive nullability needs explicit schema support")
    schema = resolve(spec, schema)
    if not isinstance(schema, dict):
        raise ValueError("boolean request schemas need explicit support")
    kind = schema.get("type")
    if kind is not None and kind != "null" and not (isinstance(kind, list) and "null" in kind) and not schema.get("nullable"):
        return False
    if "enum" in schema and None not in schema["enum"]:
        return False
    if "const" in schema and schema["const"] is not None:
        return False
    if any(key in schema for key in ("not", "if", "then", "else")):
        raise ValueError("conditional request nullability needs explicit schema support")
    for key in ("allOf", "anyOf", "oneOf"):
        if key in schema:
            matches = [allows_null(spec, branch, depth + 1) for branch in schema[key]]
            if not {"allOf": all(matches), "anyOf": any(matches), "oneOf": sum(matches) == 1}[key]:
                return False
    return True


def additions(before, after, changes):
    result = []
    for path, item in after.get("paths", {}).items():
        item = resolve(after, item)
        old_item = resolve(before, before.get("paths", {}).get(path, {}))
        for method in METHODS & item.keys() & old_item.keys():
            old_fields = request_fields(before, old_item[method], old_item)
            new_fields = request_fields(after, item[method], item)
            for field in new_fields.keys() - old_fields.keys():
                value = new_fields[field]
                if value["required"]:
                    continue
                # An added parent is tested as one value, including nested content.
                if any(field.startswith(parent + "/") for parent in new_fields.keys() - old_fields.keys()):
                    continue
                result.append({"id": f"{method.upper()} {path} {field}", "method": method.upper(),
                               "path": path, "field": field, "nullable": allows_null(after, value["schema"]), **value})
    operations = {(c.get("operation"), c.get("path")) for c in changes if c.get("id", "").startswith("new-optional-request-")}
    for method, path in operations:
        detected = sum(c.get("id", "").startswith("new-optional-request-") and c.get("operation") == method and c.get("path") == path for c in changes)
        classified = sum(f["method"] == method and f["path"] == path for f in result)
        if detected != classified:
            raise ValueError(f"unclassified optional request addition: {method} {path} ({detected} findings, {classified} fields)")
    return sorted(result, key=lambda feature: feature["id"])
