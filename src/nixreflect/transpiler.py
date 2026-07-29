# SPDX-License-Identifier: MIT

"""Core mutual-reference transpiler for NixReflect.

NixReflect emits *Nix expressions* instead of Python programs. Each emitted
``.nix`` file is a ``let ... in <body>`` expression whose bindings embed a JSON
data blob and a small framework able to reconstruct the exact source code of
every node (itself included) from that blob alone.
"""

import json
import re

from .template import Template, validate_template
from .template import node_ids as _template_node_ids


def nix_str(s: str) -> str:
    """Encode ``s`` as a Nix double-quoted string literal.

    This escaping is mirrored verbatim inside ``FRAMEWORK`` (the
    ``__nixreflect_nix_str__`` function, implemented with
    ``builtins.replaceStrings``); the two MUST stay behaviourally identical.
    ``replaceStrings`` substitutes in a single left-to-right pass and never
    rescans replacement text; the sequential ``str.replace`` calls below are
    equivalent because no replacement output re-triggers an earlier pattern.

    Args:
        s: str  The string value to encode.

    Returns:
        A Nix string literal (including the surrounding double quotes) that
        evaluates to exactly ``s``.
    """
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'


# Embedded framework (byte-identical in every node; written literally AND stored
# in the data blob from this one source value). It is a run of `let` bindings
# terminated by the `in` keyword; the node body follows as the file's result
# expression.
FRAMEWORK = r"""  # ========== NixReflect FRAMEWORK ==========

  __nixreflect_blob__ = builtins.fromJSON __nixreflect_DATA__;

  # Nix double-quoted string literal for `s`; mirrors nixreflect.transpiler.nix_str.
  __nixreflect_nix_str__ = s: "\"" + builtins.replaceStrings
    [ "\\" "\"" "\${" ] [ "\\\\" "\\\"" "\\\${" ] s + "\"";

  # Exact source code (string) of node `target`, reconstructed from embedded data.
  __nixreflect_render__ = target:
    __nixreflect_blob__.header
    + "  __nixreflect_SELF__ = " + __nixreflect_nix_str__ target + ";\n"
    + "  __nixreflect_DATA__ = " + __nixreflect_nix_str__ __nixreflect_DATA__ + ";\n"
    + "\n"
    + __nixreflect_blob__.framework + "\n"
    + __nixreflect_blob__.bodies.${target};

  __nixreflect_node_ids__ = __nixreflect_blob__.nodes;

  __nixreflect_self_id__ = __nixreflect_SELF__;
in"""

HEADER = "# auto-generated mutually-referential attestation node -- do not edit\nlet\n"


def render_node(target: str, blob: str, header: str, framework: str, body: str) -> str:
    """Lay out the source of one node file.

    This expression is mirrored verbatim inside ``FRAMEWORK`` (the
    ``__nixreflect_render__`` function); the two MUST stay structurally
    identical.

    Args:
        target: str     The node-id this file is for.
        blob: str       The JSON data blob embedded in the node.
        header: str     The shared file header (opens the ``let``).
        framework: str  The embedded framework source (closes with ``in``).
        body: str       The rewritten node body (the result expression).

    Returns:
        The complete source code of the node file.
    """
    return (
        header
        + "  __nixreflect_SELF__ = "
        + nix_str(target)
        + ";\n"
        + "  __nixreflect_DATA__ = "
        + nix_str(blob)
        + ";\n"
        + "\n"
        + framework
        + "\n"
        + body
    )


def rewrite_placeholders(code: str, ids) -> str:
    """Rewrite each bare node-id token into a ``__nixreflect_render__`` call.

    Args:
        code: str           A node body, possibly containing bare node-id tokens.
        ids: Iterable[str]  The node-ids to rewrite, matched on identifier boundaries.

    Returns:
        The rewritten body, terminated by a single trailing newline.
    """
    out = code
    for nid in ids:
        pat = r"(?<![A-Za-z0-9_])" + re.escape(nid) + r"(?![A-Za-z0-9_])"
        repl = "(__nixreflect_render__ " + nix_str(nid) + ")"
        out = re.sub(pat, lambda _m, repl=repl: repl, out)
    return out.rstrip("\n") + "\n"


def build_bodies(template: Template) -> dict[str, str]:
    """Rewrite every node body in a template.

    Args:
        template: Template The validated template.

    Returns:
        A ``{node_id: rewritten_code}`` mapping.
    """
    ids = _template_node_ids(template)
    return {
        entry["node-id"]: rewrite_placeholders(entry["code"], ids) for entry in template
    }


def build_blob(template: Template, bodies: dict[str, str] | None = None) -> str:
    """Build the JSON data blob embedded in every emitted node.

    Unlike PyReflect (which base64-encodes the blob so that Python's ``repr``
    stays trivial), NixReflect embeds the JSON text directly: pure Nix has no
    base64 decoder, but ``builtins.fromJSON`` is built in and the
    ``__nixreflect_nix_str__``/``nix_str`` pair makes the string literal
    round-trip exact.

    Args:
        template: Template              The validated template.
        bodies: dict[str, str] | None   Pre-rewritten bodies; rebuilt from
            ``template`` when ``None``.

    Returns:
        The JSON blob (ASCII str) embedded as ``__nixreflect_DATA__``.
    """
    if bodies is None:
        bodies = build_bodies(template)
    blob_obj = {
        "nodes": _template_node_ids(template),
        "bodies": bodies,
        "header": HEADER,
        "framework": FRAMEWORK,
    }
    return json.dumps(blob_obj, sort_keys=True, separators=(",", ":"))


def transpile(template: Template) -> dict[str, str]:
    """Transpile a template into standalone Nix nodes.

    Args:
        template: Template  The template to transpile (it is validated).

    Returns:
        A ``{node_id: source_code}`` mapping, one entry per node.

    Raises:
        ValueError: if the template is malformed or node-ids collide.
    """
    template = validate_template(template)
    ids = _template_node_ids(template)
    bodies = build_bodies(template)
    blob = build_blob(template, bodies)

    nodes = {nid: render_node(nid, blob, HEADER, FRAMEWORK, bodies[nid]) for nid in ids}
    return nodes
