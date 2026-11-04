# -*- coding: utf-8 -*-
r"""validate_schema.py -- validate the rendered bundle patch (and a composed dump) against the
CURRENT DeepSeek Harness's own `--dump-config-schema`.

Why this exists (2026-11-04): DSH 0.2.1-rc.5 renamed nothing but did change how a profile's
node_modules is resolved during composition; the kit had no way to prove *schema* compatibility
without booting the Electron host. `dsh --profile <p> --dump-config-schema` is that oracle, and it
can be produced from an isolated probe home (dev/make_probe_home.py). This script turns it into a
gate: if a future DSH release changes an entry/patch shape the kit renders, the maintainer sees it
before shipping instead of after a session silently loses tools.

Usage:
  py dev/validate_schema.py --schema <schema.json> --patch <rendered cordis.patch.yml>
  py dev/validate_schema.py --schema <schema.json> --entries <dump-config.yml>
  py dev/validate_schema.py --schema <schema.json> --patch <p> --entries <d>

Inputs may be UTF-16 (Windows PowerShell `>` redirection writes UTF-16) or UTF-8 (with/without BOM).
Exit codes: 0 = PASS, 1 = schema violation, 2 = setup problem (missing jsonschema / unreadable file).

Dependencies: PyYAML (already required by dev/validate_patch.py) and `jsonschema`. `jsonschema`
is NOT vendored: when it is missing this script exits 2 with the install hint, exactly like
validate_patch.py does for PyYAML -- a gate that cannot run must say so, never pass silently.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - environment problem, not a code path
    print("[ERROR] PyYAML is missing: py -m pip install pyyaml", file=sys.stderr)
    sys.exit(2)

try:
    import jsonschema
except ModuleNotFoundError:  # pragma: no cover
    print("[ERROR] jsonschema is missing: py -m pip install jsonschema", file=sys.stderr)
    sys.exit(2)


class _TolerantLoader(yaml.SafeLoader):
    """Cordis entry lists carry `!!js <expression>`; keep it as data, do not evaluate it."""


def _js_node(loader, _suffix, node):
    # The runtime's schema models a `!!js <expression>` as {"__jsExpr": "<source>"} (see
    # $defs.loaderExpression). Mapping it to anything else (e.g. {"__js__": ...}) makes valid host
    # rows look invalid, which is a validator bug, not a kit bug.
    if isinstance(node, yaml.ScalarNode):
        return {"__jsExpr": node.value}
    if isinstance(node, yaml.SequenceNode):
        return {"__jsExpr": "<sequence>"}
    return {"__jsExpr": "<mapping>"}


_TolerantLoader.add_multi_constructor("!", _js_node)
_TolerantLoader.add_multi_constructor("tag:yaml.org,2002:", lambda l, s, n: _js_node(l, s, n))


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    return raw.decode("utf-8-sig")


def load_yaml(path: Path):
    return yaml.load(read_text(path), Loader=_TolerantLoader)


def main() -> int:
    ap = argparse.ArgumentParser(description="validate kit YAML against the runtime's config schema")
    ap.add_argument("--schema", required=True, help="JSON schema from `dsh --profile <p> --dump-config-schema`")
    ap.add_argument("--patch", default="", help="rendered cordis.patch.yml (validated as a patch list)")
    ap.add_argument("--entries", default="", help="composed `--dump-config` output (validated as an entry list)")
    ap.add_argument("--max-errors", type=int, default=25)
    args = ap.parse_args()

    schema_path = Path(args.schema)
    if not schema_path.is_file():
        print("[ERROR] schema file not found: {0}".format(schema_path), file=sys.stderr)
        return 2
    schema = json.loads(read_text(schema_path))
    defs = schema.get("$defs") or {}
    if not defs:
        print("[ERROR] schema has no $defs (not a DSH --dump-config-schema document?)", file=sys.stderr)
        return 2

    targets = []
    if args.patch:
        targets.append(("patch", Path(args.patch), "#/$defs/patchList"))
    if args.entries:
        targets.append(("entries", Path(args.entries), "#/$defs/entryList"))
    if not targets:
        print("[ERROR] pass --patch and/or --entries", file=sys.stderr)
        return 2

    failed = False
    for label, path, ref in targets:
        if not path.is_file():
            print("[ERROR] {0} file not found: {1}".format(label, path), file=sys.stderr)
            return 2
        data = load_yaml(path)
        validator = jsonschema.Draft202012Validator({"$ref": ref, "$defs": defs})
        errors = sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))
        count = len(data) if isinstance(data, list) else 1
        if errors:
            failed = True
            print("[FAIL] {0} ({1}): {2} violation(s) in {3} entr{4}".format(
                label, path, len(errors), count, "y" if count == 1 else "ies"))
            for err in errors[:args.max_errors]:
                print("   - at {0}: {1}".format(list(err.absolute_path), err.message[:300]))
            if len(errors) > args.max_errors:
                print("   ... {0} more".format(len(errors) - args.max_errors))
        else:
            print("[PASS] {0} ({1}): {2} entries, 0 schema violations".format(label, path, count))
    print("=== SCHEMA: {0} ===".format("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
