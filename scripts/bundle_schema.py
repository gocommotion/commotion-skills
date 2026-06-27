#!/usr/bin/env python3
"""Bundle a named schema out of an OpenAPI spec into one self-contained JSON Schema.

Reads the OpenAPI spec (JSON) on stdin and the root schema name as the first argument,
and prints that schema inlined at the top level with the transitive closure of its
``$ref`` dependencies under ``$defs`` (refs rewritten ``#/components/schemas/X`` →
``#/$defs/X``). Including only the closure keeps the result small.

Stdlib-only port of ``commotion-mcp/server/utils/openapi.py`` so the skill produces a
byte-equivalent request schema without the MCP server. Exits non-zero with a message on
a missing/invalid schema or unparseable spec.

Usage:
    bundle_schema.py <SchemaName> < api-docs.json
"""

import json
import sys
from typing import Any, Iterator

_REF_PREFIX = "#/components/schemas/"
_JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"


def _iter_ref_names(node: Any) -> Iterator[str]:
    """Yield every ``components/schemas`` name referenced anywhere under ``node``."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str) and value.startswith(_REF_PREFIX):
                yield value[len(_REF_PREFIX) :]
            else:
                yield from _iter_ref_names(value)
    elif isinstance(node, list):
        for item in node:
            yield from _iter_ref_names(item)


def _rewrite_refs(node: Any) -> Any:
    """Deep-copy ``node``, rewriting ``components/schemas`` refs to ``$defs`` refs."""
    if isinstance(node, dict):
        out: dict[str, Any] = {}
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str) and value.startswith(_REF_PREFIX):
                out[key] = f"#/$defs/{value[len(_REF_PREFIX):]}"
            else:
                out[key] = _rewrite_refs(value)
        return out
    if isinstance(node, list):
        return [_rewrite_refs(item) for item in node]
    return node


def bundle_schema(spec: Any, root_name: str) -> dict[str, Any]:
    components = spec.get("components") if isinstance(spec, dict) else None
    schemas = components.get("schemas") if isinstance(components, dict) else None
    if not isinstance(schemas, dict) or root_name not in schemas:
        raise LookupError(f"schema {root_name!r} not found in OpenAPI components")
    root = schemas[root_name]
    if not isinstance(root, dict):
        raise LookupError(f"schema {root_name!r} is not an object")

    closure: set[str] = set()
    queue: list[str] = [root_name]
    while queue:
        for ref in _iter_ref_names(schemas.get(queue.pop())):
            if ref not in closure and ref in schemas:
                closure.add(ref)
                queue.append(ref)

    defs = {name: _rewrite_refs(schemas[name]) for name in sorted(closure)}
    return {
        "$schema": _JSON_SCHEMA_DIALECT,
        **_rewrite_refs(root),
        "title": root_name,
        "$defs": defs,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: bundle_schema.py <SchemaName> < api-docs.json", file=sys.stderr)
        return 2
    root_name = sys.argv[1]
    try:
        spec = json.load(sys.stdin)
    except ValueError as exc:
        print(f"error: could not parse OpenAPI spec on stdin: {exc}", file=sys.stderr)
        return 1
    try:
        bundled = bundle_schema(spec, root_name)
    except LookupError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(bundled, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
