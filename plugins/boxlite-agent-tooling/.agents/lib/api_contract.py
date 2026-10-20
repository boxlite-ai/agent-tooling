"""Read immutable inputs and derive API review obligations; no state writes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

SPEC = "openapi/box.openapi.yaml"
CONFIG = ".agent-tooling/api-compatibility.json"
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


def link_target(name, target):
    """Return a symlink target that stays inside the repository; snapshots recreate the link."""
    if os.path.isabs(target) or os.path.normpath(os.path.join(os.path.dirname(name), target)).split(os.sep)[0] == "..":
        raise ValueError(f"symlink leaves the repository: {name}")
    return target


def source_files(root):
    names = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    files, links = {}, {}
    for name in sorted(set(names.decode().split("\0")) - {""}):
        path = root / name
        if path.is_symlink():
            links[name] = link_target(name, os.readlink(path))
        elif path.is_file():
            files[name] = path.read_bytes()
        elif path.exists():
            raise ValueError(f"unsupported source entry: {name}")
    for name in (SPEC, CONFIG):
        if name in links:
            raise ValueError(f"{name} must be a regular file")
    return files, links


def load_inputs(root, explicit_base):
    files, links = source_files(root)
    config = json.loads(files.get(CONFIG, b"{}"))
    if not isinstance(config, dict):
        raise ValueError("compatibility configuration must be an object")
    base_ref = explicit_base or config.get("baseRef")
    if not base_ref:
        for ref in ("origin/main", "main"):
            if subprocess.run(["git", "rev-parse", "--verify", ref], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                base_ref = ref
                break
    if not base_ref or not isinstance(base_ref, str) or base_ref.startswith("-"):
        raise ValueError("set baseRef or pass --base to identify the pre-change revision")
    base = git(root, "merge-base", "HEAD", base_ref).decode().strip()
    old = subprocess.run(["git", "show", f"{base}:{SPEC}"], cwd=root, capture_output=True)
    before = old.stdout if old.returncode == 0 else None
    after = files.get(SPEC)
    if before == after:
        staged = subprocess.run(["git", "show", f":{SPEC}"], cwd=root, capture_output=True)
        if staged.returncode == 0 and staged.stdout != after:
            raise ValueError("staged OpenAPI differs from the working copy; audit the intended changes")
        return None
    if before is None or after is None:
        raise ValueError("adding or deleting the complete Box API contract requires manual review")
    tooling = Path(__file__).resolve().parents[2]
    policy = {p: hashlib.sha256((tooling / p).read_bytes()).hexdigest() for p in (
        ".agents/lib/api_contract.py", ".agents/lib/api_requests.py",
        "scripts/api-compatibility.py", "scripts/api-compatibility.sh")}
    fingerprint = digest({"base": base, "files": {p: [hashlib.sha256(v).hexdigest(), (root / p).stat().st_mode & 0o777] for p, v in files.items()},
                          "links": links, "policy": policy, "oasdiff": OASDIFF_VERSION})
    changed = set(git(root, "diff", "--name-only", base, "--").decode().splitlines())
    changed.update(git(root, "ls-files", "--others", "--exclude-standard").decode().splitlines())
    return {"base": base, "files": files, "links": links, "before": before, "after": after,
            "config": config, "fingerprint": fingerprint, "changed": changed}


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


def required_cases(inputs, features):
    config = inputs["config"]
    if features and not config.get("sdks"):
        raise ValueError(f"declare SDK source mappings in {CONFIG}")
    required = []
    names = set()
    for sdk in config.get("sdks", []):
        if not sdk.get("name") or not sdk.get("paths") or not isinstance(sdk.get("command"), list) or not sdk["command"]:
            raise ValueError("SDK mapping requires name, paths, and an adapter argv command")
        if sdk["name"] in names or not all(isinstance(arg, str) and arg for arg in sdk["command"]):
            raise ValueError("SDK names must be unique and commands must contain nonempty strings")
        names.add(sdk["name"])
        if not all(isinstance(p, str) and p and not p.startswith(("/", "..")) for p in sdk["paths"]):
            raise ValueError("SDK source paths must be repository-relative prefixes")
        if not any(p == prefix or p.startswith(prefix.rstrip("/") + "/") for p in inputs["changed"] for prefix in sdk["paths"]):
            continue
        for feature in features:
            declaration = config.get("features", {}).get(feature["id"])
            if not isinstance(declaration, dict) or "nonDefault" not in declaration:
                raise ValueError(f"declare nonDefault and stub response for {feature['id']}")
            schema = feature["schema"]
            if "default" in schema and canonical(schema["default"]) == canonical(declaration["nonDefault"]):
                raise ValueError(f"nonDefault equals the default: {feature['id']}")
            cases = ["omitted", "non-default"]
            if "default" in schema:
                cases.append("default")
            if feature["nullable"] or declaration.get("nullIsOmitted") is True:
                if type(declaration.get("nullIsOmitted")) is not bool:
                    raise ValueError(f"declare nullIsOmitted for {feature['id']}")
                cases.append("null")
            required.append({"sdk": sdk, "feature": feature, "declaration": declaration, "cases": cases})
    return required
