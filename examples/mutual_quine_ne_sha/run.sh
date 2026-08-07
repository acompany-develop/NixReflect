#!/bin/bash
# SPDX-License-Identifier: MIT
#
# NixReflect mutual quine, Nitro Enclave SHA-384 edition -- enclave entrypoint.
#
# Runs inside the enclave (NIXREFLECT_ROOT unset, i.e. against /) or inside the
# `verify` derivation sandbox (NIXREFLECT_ROOT=<a node's pristine rootfs>).
# Reconstructs the peer's node.nix source from data embedded in this image
# alone -- no network, no files from outside -- and prints its SHA-384 digest.
# Unlike mutual_quine_ne_pcrs, nothing is rebuilt here: the peer's EIF (and
# hence its PCRs) is never assembled inside the enclave.
#
# @appEnv@ is substituted by default.nix and is identical between the two
# enclave images; the images differ only in /app/node.nix.
set -eu
umask 0022
export LC_ALL=C

ROOT="${NIXREFLECT_ROOT:-}"
OUT="${NIXREFLECT_OUT:-/tmp/nixreflect}"
HOLD="${NIXREFLECT_HOLD:-1}"

export PATH="@appEnv@/bin"

work="$(mktemp -d)"
mkdir -p "$OUT"

# nix only evaluates a single self-contained file (nothing is built or
# fetched), but it still wants writable state and cache locations.
export HOME="$work/home"
export XDG_CACHE_HOME="$work/cache"
export NIX_STATE_DIR="$work/nix/state"
export NIX_LOG_DIR="$work/nix/log"
export NIX_CONF_DIR="$work/nix/conf"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$NIX_STATE_DIR" "$NIX_LOG_DIR" "$NIX_CONF_DIR"

echo "==[ NixReflect mutual quine -- Nitro Enclave SHA-384 edition ]=="

# 1. Evaluate our own node file (a Nix Quine).
nix-instantiate --eval --strict --json "$ROOT/app/node.nix" > "$work/eval.json"
SELF_ID="$(jq -r .self "$work/eval.json")"
PEER_ID="$(jq -r .peer "$work/eval.json")"
echo "self: $SELF_ID"
echo "peer: $PEER_ID"

# -j, not -r: the rendered sources already end in a newline.
jq -j .selfSource "$work/eval.json" > "$work/node-self.nix"
jq -j .peerSource "$work/eval.json" > "$OUT/peer-node.nix"

# Quine sanity check: the source this image reconstructs for itself must be
# exactly the file it reconstructs it from.
cmp "$work/node-self.nix" "$ROOT/app/node.nix"
echo "self-render is byte-identical to /app/node.nix"

# 2. Hash the reconstructed peer source. SHA-384 to match the digest family
#    Nitro PCRs use (builtins.hashString cannot do SHA-384; coreutils can).
sha384sum "$OUT/peer-node.nix" | cut -d" " -f1 > "$OUT/peer-sha384"

echo
echo "==[ SHA-384 of the source of peer enclave $PEER_ID ]=="
cat "$OUT/peer-sha384"
echo
echo "compare against sha384sum of the peer's /app/node.nix."

if [ "$HOLD" = "1" ]; then
  # keep the enclave alive so the console output can be read at leisure
  while true; do sleep 3600; done
fi
