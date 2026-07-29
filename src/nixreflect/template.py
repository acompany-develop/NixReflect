# SPDX-License-Identifier: MIT

"""Template parsing and validation for NixReflect."""

import json
from typing import Required, TypedDict


class Node(TypedDict):
    """A single template entry."""

    node_id: Required[str]
    code: Required[str]


# Internal canonical representation keeps the JSON key names ("node-id"),
# since the transpiler and manifest format are defined in terms of them.
Template = list[dict]


def parse_template(text: str) -> Template:
    """Decode and validate a template from its JSON text.

    Args:
        text: str   JSON text encoding a list of node objects.

    Returns:
        The validated template (a list of ``{"node-id", "code"}`` dicts).

    Raises:
        ValueError: if the JSON is invalid or the template is malformed.
    """
    return validate_template(json.loads(text))


def validate_template[T](template: T) -> Template:
    """Validate a decoded template JSON object, returning it unchanged.

    Args:
        template: T The decoded JSON object to validate (expected to be a list of
            node objects).

    Returns:
        The same object, validated and typed as ``Template``.

    Raises:
        ValueError: if the structure is malformed or node-ids collide.
    """
    if not isinstance(template, list):
        raise ValueError("template must be a JSON list")

    for entry in template:
        if not isinstance(entry, dict):
            raise ValueError("each template entry must be an object")
        if "node-id" not in entry or "code" not in entry:
            raise ValueError("each template entry needs 'node-id' and 'code'")
        if not isinstance(entry["node-id"], str):
            raise ValueError("'node-id' must be a string")
        if not isinstance(entry["code"], str):
            raise ValueError("'code' must be a string")

    ids = [entry["node-id"] for entry in template]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate node-id in template")

    return template


def node_ids(template: Template) -> list[str]:
    """List the node ids of a template.

    Args:
        template: Template  The validated template.

    Returns:
        The node ids, in the order they appear in the template.
    """
    return [entry["node-id"] for entry in template]
