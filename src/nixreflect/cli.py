# SPDX-License-Identifier: MIT

"""Command-line entry point for NixReflect."""

import argparse
import json
import os
import re
import sys

from . import __version__
from .template import Template, node_ids, parse_template
from .transpiler import transpile


def read_file(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def load_template(path: str) -> Template:
    text = sys.stdin.read() if path == "-" else read_file(path)
    return parse_template(text)


def node_filename(node_id: str) -> str:
    return "node_" + re.sub(r"[^A-Za-z0-9_]", "_", node_id) + ".nix"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nixreflect",
        description="Transpile a template into standalone Nix nodes.",
    )
    parser.add_argument(
        "template",
        metavar="TEMPLATE.json",
        help="template JSON file, or '-' to read from stdin",
    )
    parser.add_argument(
        "outdir",
        metavar="OUTPUT_DIR",
        help="directory to write node_<id>.nix files and manifest.json into",
    )
    parser.add_argument(
        "--version",
        action="version",
        version="%(prog)s " + __version__,
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        template = load_template(args.template)
        nodes = transpile(template)
        ids = node_ids(template)
        manifest = {nid: node_filename(nid) for nid in ids}

        os.makedirs(args.outdir, exist_ok=True)
        for nid, filename in manifest.items():
            with open(os.path.join(args.outdir, filename), "w", encoding="utf-8") as f:
                f.write(nodes[nid])
        with open(
            os.path.join(args.outdir, "manifest.json"), "w", encoding="utf-8"
        ) as f:
            json.dump(manifest, f, indent=2)
    except (ValueError, OSError) as exc:
        sys.stderr.write("nixreflect: %s\n" % exc)
        return 1

    print("generated %d node(s) in %s:" % (len(manifest), os.path.abspath(args.outdir)))
    for nid, filename in manifest.items():
        print("  %-14s -> %s" % (nid, filename))
    print("  manifest      -> manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
