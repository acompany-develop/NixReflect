# NixReflect

![SemVer](https://img.shields.io/badge/NixReflect-0.1.0-white)
![Python Version](https://img.shields.io/badge/Python-3.12-blue)
![Nix](https://img.shields.io/badge/Nix-flakes-5277C3)
[![License](https://img.shields.io/badge/License-MIT-red)](/LICENSE)

A transpiler for mutually-referential reflective programming in **Nix** — the Nix-targeting sibling of [PyReflect](https://github.com/acompany-develop/PyReflect).
The transpiler is implemented in Python and is available as a library (`nixreflect`) and a command-line tool (`nixreflect`); its *output* is a set of mutually-referential standalone `.nix` files.

## Overview

NixReflect is a transpiler that makes *mutually-referential* programs — programs made of several nodes — possible.
Every node can reference the source code of itself and of the other nodes, without relying on any external source (e.g. file, stdin, registry).

Naïvely embedding each node's code inside the others has no solution — it is a fixed-point problem with an infinite regress.
**Kleene's second recursion theorem** dissolves it: instead of the code itself, each node embeds a *code generator* together with its input data, from which the exact code of every node (itself and its peers) can be reconstructed intrinsically.
For the full background, see [PyReflect's README](https://github.com/acompany-develop/PyReflect#readme) — NixReflect is the same construction with Nix as the target language.

Because the generated nodes are Nix expressions, and Nix builds are deterministic functions of their sources, the reflection extends beyond source code: a node can intrinsically derive any *reproducible build artifact* of its peers — hashes, container layers, or (see below) AWS Nitro Enclave images and their measurements.

## Install

```bash
uv pip install git+https://github.com/acompany-develop/NixReflect
```

This exposes the `nixreflect` command and the importable `nixreflect` package.
Alternatively, with Nix:

```bash
nix run .#nixreflect -- TEMPLATE.json OUTPUT_DIR
```

## Usage

### Library API

```py
from nixreflect import parse_template, transpile

with open(path, encoding="utf-8") as f:
    # Read
    text = f.read()
    # Parse
    template = parse_template(text)
    # Transpile
    nodes = transpile(template)
```

### Transpiler CLI

```bash
# Input from file
nixreflect TEMPLATE.json OUTPUT_DIR

# Input from stdin
cat TEMPLATE.json | nixreflect - OUTPUT_DIR
```

It writes one file per node (`node_<id>.nix`) with a `manifest.json` mapping node-id to filename.

## Transpiler details

The template format, the transformation, and the framework API are the same as [PyReflect's](https://github.com/acompany-develop/PyReflect#readme), with `__nixreflect_*__` in place of `__pyreflect_*__` — see there for the full specification.
The Nix-specific differences:

- A `code` body must be a single **Nix expression**; it becomes the emitted file's result expression.
  Node-id tokens are rewritten into the function application `(__nixreflect_render__ "<target-node-id>")`.
- Where PyReflect embeds the template as a Base64 blob decoded at runtime, NixReflect embeds the JSON text directly as a string literal (`__nixreflect_DATA__`) — pure Nix has no Base64 decoder, but `builtins.fromJSON` is built in.
  The framework's `__nixreflect_nix_str__` mirrors the transpiler's string-literal escaping exactly, which is what makes the reconstruction byte-exact.

## Example code

Generated `.nix` files are evaluated with `nix eval` (any recent Nix with `nix-command` enabled; `nix-instantiate --eval --strict` works too).

### quine

Single node that evaluates to its own code.

```bash
# Transpile
nixreflect examples/quine/template.json examples/quine/

# Run Node: Display its own code
nix eval --raw -f examples/quine/node___NODE.nix

# Verify
nix eval --raw -f examples/quine/node___NODE.nix | diff - examples/quine/node___NODE.nix
```

### mutual_quine

Two nodes, each of which evaluates to the other's *SHA-256 digest*.
The peer value is obtained intrinsically — node 1 reconstructs node 2's source from its own embedded data and hashes it, and vice versa — so node 1's self hash equals the value node 2 reports as its expected peer reference, and vice versa.

```bash
# Transpile
nixreflect examples/mutual_quine/template.json examples/mutual_quine/

# Run Node 1: Display the SHA-256 digest of Node 2
nix eval --raw -f examples/mutual_quine/node___NODE1.nix; echo
# Run Node 2: Display the SHA-256 digest of Node 1
nix eval --raw -f examples/mutual_quine/node___NODE2.nix; echo

# Verify
sha256sum examples/mutual_quine/*.nix
```

### trinity_quine

A variant of `mutual_quine` with three nodes wired into a cycle: node 1 yields node 2's digest, node 2 yields node 3's, node 3 yields node 1's (1 → 2 → 3 → 1).
It demonstrates that the transpiler handles arbitrary n-node reference graphs, not just the symmetric two-node case.

```bash
# Transpile
nixreflect examples/trinity_quine/template.json examples/trinity_quine/

# Run Nodes
nix eval --raw -f examples/trinity_quine/node___NODE1.nix; echo
nix eval --raw -f examples/trinity_quine/node___NODE2.nix; echo
nix eval --raw -f examples/trinity_quine/node___NODE3.nix; echo

# Verify
sha256sum examples/trinity_quine/*.nix
```

### mutual_quine_ne_sha — mutual quine as AWS Nitro Enclaves (source digests)

Two **Nitro Enclave images** (EIFs), built with [monzo/aws-nitro-util](https://github.com/monzo/aws-nitro-util), that differ in exactly one file — the quine node — and at runtime *each reconstructs the other's exact Nix source and prints its SHA-384 digest*, with no network and no shared state.
Nothing is rebuilt inside the enclave: this is the Kleene fixed point of `mutual_quine`, demonstrated in isolation on Nitro hardware, and the gentle on-ramp to the full PCR reconstruction below.

Unlike the examples above, running it requires an **EC2 instance with AWS Nitro Enclaves enabled**, but only modest resources (~2 GiB of enclave memory).
See the tutorial in [`examples/mutual_quine_ne_sha/`](examples/mutual_quine_ne_sha/README.md).

### mutual_quine_ne_pcrs — mutual quine as AWS Nitro Enclaves (reference PCRs)

The full scheme: the two EIFs are built *reproducibly*, and each enclave *rebuilds the other enclave's image inside itself at runtime* and prints the peer's reference **PCR values** — the measurements the Nitro hypervisor attests — derived intrinsically, with no network and no shared state.

Running this one requires an **EC2 instance with AWS Nitro Enclaves enabled** and ample resources — it builds the EIFs on the host and each enclave rebuilds its peer's EIF in RAM (the tested setups are `m6a.xlarge` for x86\_64 and `m6g.xlarge` for AArch64: 4 vCPUs / 16 GiB, of which 2 vCPUs / 8 GiB go to the enclave).
See the full tutorial in [`examples/mutual_quine_ne_pcrs/`](examples/mutual_quine_ne_pcrs/README.md) for the instance prerequisites, host setup, and a step-by-step walk-through.

## Tests

All examples are covered end to end by flake checks ([`examples/checks.nix`](examples/checks.nix)), run in CI on every push:

```bash
nix flake check -L
```

For each example this transpiles the template from scratch, asserts the output is byte-identical to the committed node files, evaluates the emitted nodes and asserts their quine property (self-reproduction / peer digests).

For the Nitro Enclave examples the `mutual-quine-ne-sha-verify-*` and `mutual-quine-ne-pcrs-verify-*` checks additionally re-run the enclave entrypoint against each image's rootfs and demand that what it reconstructs for its peer — the peer's source and SHA-384 digest (`_sha`), or the peer's EIF and PCRs (`_pcrs`) — matches the peer's actual build; the mutual-quine property is proven without Nitro hardware.
