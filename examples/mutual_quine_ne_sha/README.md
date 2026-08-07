# Mutual Quine as two AWS Nitro Enclaves — SHA-384 edition

This tutorial builds **two Nitro Enclave image files (EIFs)** such that, at runtime, *each enclave reconstructs the exact Nix source of the other and prints its SHA-384 digest* — without ever talking to the other enclave, the host, or the network.
Everything an enclave needs to know about its peer is embedded in its own image.

It is the **lighter sibling of [`mutual_quine_ne_pcrs`](../mutual_quine_ne_pcrs/README.md)**: real Nitro Enclaves are still built and booted, but *nothing is rebuilt inside the enclave*.
Where `mutual_quine_ne_pcrs` re-stages the peer's rootfs, re-packs its ramdisk, and re-runs `eif_build` in RAM to obtain the peer's reference **PCRs**, this example stops after the quine step: evaluate `/app/node.nix`, reconstruct the peer's source, hash it.
No `eif_build`, no payload of EIF build inputs, far less enclave memory.

## What this shows — and what it deliberately doesn't

The [`mutual_quine_ne_pcrs`](../mutual_quine_ne_pcrs/README.md) scheme is two ideas composed:

1. **Kleene's second recursion theorem** (via NixReflect) — each node can reconstruct the exact source of every node, itself included, from data embedded in itself alone;
2. **reproducible builds** (via [monzo/aws-nitro-util](https://github.com/monzo/aws-nitro-util)) — a pure, pinned function from that source to the peer's EIF, and hence to its reference PCRs.

This example demonstrates idea 1 **in isolation** on Nitro hardware.
The printed digest is over the peer's *source*, not over its *image*: it is **not** a measurement the Nitro hypervisor attests, so it cannot be checked against an attestation document.
Turning "I know my peer's source" into "I know my peer's reference PCRs" is exactly the reproducible-build step that `mutual_quine_ne_pcrs` adds on top.

SHA-384 is used (rather than the SHA-256 of the plain [`mutual_quine`](../mutual_quine) example) to match the digest family of Nitro PCRs.
Nix's `builtins.hashString` does not support SHA-384, so the hash is computed with coreutils' `sha384sum` over the reconstructed source file.

## Image layout

Both EIFs are assembled by `aws-nitro-util` from:

| EIF section | content | node1 vs node2 |
| --- | --- | --- |
| kernel + cmdline | AWS-provided blob | identical |
| bootstrap ramdisk | `init` (compiled from source) + `nsm.ko` | **identical** (the enclaves share PCR1) |
| user ramdisk | `/env`, `/cmd`, `/rootfs/**` | **differs in exactly one file** |

Unlike `mutual_quine_ne_pcrs` there is no `/node-id` in the bootstrap ramdisk (nothing selects a peer ramdisk at runtime, so nothing needs one) and no payload of EIF build inputs in the rootfs.

The user ramdisk's rootfs contains:

- `/nix/store/**` — the closure of the tool set the enclave needs at runtime (`bash`, `coreutils`, `diffutils`, `jq`, `nix`). Identical for both.
- `/app/run` — the entrypoint (identical),
- `/app/node.nix` — the NixReflect-transpiled quine node.
  **The only file that differs between the two images.**

At runtime `/app/run`:

1. evaluates `/app/node.nix` with `nix-instantiate` — the quine yields `{ self, peer, selfSource, peerSource }`;
2. sanity-checks that `selfSource` is byte-identical to its own `/app/node.nix`;
3. runs `sha384sum` over `peerSource` and prints the digest: an intrinsically derived digest of the peer's exact source.

## Expected digests

The node sources — and therefore the digests — depend only on [`template.json`](template.json) and the transpiler in this repo: unlike the PCRs of `mutual_quine_ne_pcrs`, they are independent of `flake.lock`'s tool pins and of the architecture.
With the committed template and transpiler:

| file | SHA-384 |
| --- | --- |
| `node___ENCLAVE1.nix` | `1b9ac63487aae18376a2dfae69db04e526495c4c9a2892e4528fe36941a14f2c0a16a81e7b5e3fb30609c81c9b19b699` |
| `node___ENCLAVE2.nix` | `b0458a2fa18fef7ccd62fc80eb8e49dc489a4408920ad4905b4b6037db30b1a4357ec558502b601f5eda17691b5a744f` |

So enclave 1 prints node 2's digest (`b0458a…`) and enclave 2 prints node 1's (`1b9ac6…`).

## Prerequisites

Same as [`mutual_quine_ne_pcrs`](../mutual_quine_ne_pcrs/README.md#prerequisites): a build machine with Nix + flakes, and an EC2 instance with Nitro Enclaves enabled whose architecture matches the EIF's.
The host setup scripts live in the sibling example:

```bash
ALLOCATOR_MEMORY_MIB=2048 ../mutual_quine_ne_pcrs/scripts/setup-nitro-cli.sh
```

Since nothing is rebuilt in RAM here, a much smaller allocator suffices — 2048 MiB is plenty for the tool closure plus `nix-instantiate` (raise it if `nitro-cli run-enclave` reports insufficient memory).

### Tested environment

Last verified end to end on **2026-08-07**, on the **AArch64** host of [`mutual_quine_ne_pcrs`'s tested environment](../mutual_quine_ne_pcrs/README.md#tested-environment) (`m6g.xlarge`, Ubuntu 26.04 LTS, nitro-cli 1.4.5, Determinate Nix 3.21.8): both enclaves booted with 2048 MiB / 2 CPUs on real Nitro hardware, each printed exactly the SHA-384 digest of its peer's node file, and for a non-debug run of each image the PCR0–2 reported by the hypervisor (`nitro-cli describe-enclaves --metadata`) matched the image's build-time `pcr.json`.
Unlike the PCRs, the [expected digests](#expected-digests) are architecture-independent — an x86\_64 run prints the same values.

## Run

### Step 1 — transpilation (optional)

From the repo root:

```bash
nix build .#mutual-quine-ne-sha-nodes -o nodes
cat nodes/node___ENCLAVE1.nix
sha384sum nodes/node___ENCLAVE*.nix   # the digests the enclaves will print
```

You can also run the transpiler directly, without Nix:

```bash
PYTHONPATH=src python3 -m nixreflect examples/mutual_quine_ne_sha/template.json out/
```

Each node evaluates to `{ self, peer, selfSource, peerSource }`, reconstructed entirely from the JSON blob embedded in the node itself.

### Step 2 — EIF build

```bash
nix build .#mutual-quine-ne-sha-eif1 -o eif1
nix build .#mutual-quine-ne-sha-eif2 -o eif2
```

### Step 3 — hardware-free verification

The flake ships checks that re-run **the exact enclave entrypoint** against each image's pristine rootfs, and demand that both the source and the SHA-384 digest it reconstructs for its peer match the peer's actual node file:

```bash
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).mutual-quine-ne-sha-verify-1-hashes-2
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).mutual-quine-ne-sha-verify-2-hashes-1
# or simply:
nix flake check
```

If these pass, what the enclaves will print on real hardware is already determined to be correct.

### Step 4 — run on Nitro Enclaves

**Enclave 1** — boot it and attach to its console:

```bash
nitro-cli run-enclave \
  --eif-path eif1/image.eif \
  --memory 2048 --cpu-count 2 \
  --debug-mode

nitro-cli console --enclave-id "$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveID')"
```

After boot, enclave 1 evaluates its quine and prints:

```console
==[ NixReflect mutual quine -- Nitro Enclave SHA-384 edition ]==
warning: the group 'nixbld' specified in 'build-users-group' does not exist
self: __ENCLAVE1
peer: __ENCLAVE2
self-render is byte-identical to /app/node.nix

==[ SHA-384 of the source of peer enclave __ENCLAVE2 ]==
b0458a2fa18fef7ccd62fc80eb8e49dc489a4408920ad4905b4b6037db30b1a4357ec558502b601f5eda17691b5a744f

compare against sha384sum of the peer's /app/node.nix.
```

— exactly `sha384sum` of node 2's `/app/node.nix`.
Terminate it, then repeat with `eif2/image.eif`: enclave 2 prints node 1's digest (`1b9ac6…`).

```bash
nitro-cli terminate-enclave --all
```

## Comparison with `mutual_quine_ne_pcrs`

| | `mutual_quine_ne_sha` (this) | [`mutual_quine_ne_pcrs`](../mutual_quine_ne_pcrs/README.md) |
| --- | --- | --- |
| printed for the peer | SHA-384 of its *source* | its reference *PCRs* (SHA-384 of its EIF sections) |
| in-enclave work | `nix-instantiate` + `sha384sum` | `nix-instantiate` + rootfs re-stage + `cpio\|gzip` re-pack + `eif_build` |
| tools packed into the image | `bash`, `coreutils`, `diffutils`, `jq`, `nix` | those + `findutils`, `cpio`, `gzip`, `eif_build`, and byte-copies of every EIF build input |
| bootstrap ramdisk | shared (PCR1 equal) | per-node `/node-id` (PCR1 differs) |
| enclave memory | ~2 GiB | ~8 GiB |
| output depends on | template + transpiler only | additionally `flake.lock` and architecture |
| usable against an attestation document | no — sources are not measured | **yes** — PCRs are what the NSM attests |

## Notes

- **`--debug-mode`** lets you read the console; run without it for real attestation experiments (irrelevant here — this example never touches the NSM).
- The digest values above are pure functions of the committed template and transpiler; if either changes, re-derive them with `sha384sum nodes/node___ENCLAVE*.nix` (Step 1).
- Hardware-free `verify` checks (Step 3) prove the printed output correct without an EC2 instance; booting the enclaves only demonstrates that the same computation runs under the Nitro hypervisor.

## References

See [`mutual_quine_ne_pcrs`'s references](../mutual_quine_ne_pcrs/README.md#references); background on Nitro Enclaves attestation and the TTP-free mutual-attestation motivation is there.
