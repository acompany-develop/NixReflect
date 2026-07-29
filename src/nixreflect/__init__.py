# SPDX-License-Identifier: MIT

"""NixReflect -- a general mutual-reference transpiler targeting Nix.

Turns a template describing N nodes into N standalone Nix expressions, each able
to reconstruct the exact source of every node (itself included) from data
embedded in itself.

Public API::

    from nixreflect import parse_template, transpile

    template = parse_template(text)
    nodes = transpile(template)   # {node_id: source_code}
"""

__version__ = "0.1.0"

from .template import (
    Node,
    Template,
    node_ids,
    parse_template,
    validate_template,
)
from .transpiler import (
    FRAMEWORK,
    HEADER,
    build_blob,
    build_bodies,
    nix_str,
    render_node,
    rewrite_placeholders,
    transpile,
)

__all__ = [
    "__version__",
    "Node",
    "Template",
    "parse_template",
    "validate_template",
    "node_ids",
    "transpile",
    "build_blob",
    "build_bodies",
    "nix_str",
    "rewrite_placeholders",
    "render_node",
    "FRAMEWORK",
    "HEADER",
]
