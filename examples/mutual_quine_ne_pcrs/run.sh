#!/bin/bash
# SPDX-License-Identifier: MIT
#
# NixReflect mutual quine, Nitro Enclave edition -- enclave entrypoint.
#
# Runs inside the enclave (NIXREFLECT_ROOT unset, i.e. against /) or inside the
# `verify` derivation sandbox (NIXREFLECT_ROOT=<a node's pristine rootfs>).
# Reconstructs the peer's EIF byte-for-byte from data embedded in this image
# alone -- no network, no files from outside -- and prints the peer's
# reference PCR values.
#
# @tokens@ are substituted by default.nix; every substituted store path is
# identical between the two enclave images. The images differ only in
# /app/node.nix (user ramdisk) and /node-id (bootstrap ramdisk), both
# derivable for the peer via the Quine framework.
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

echo "==[ NixReflect mutual quine -- Nitro Enclave edition ]=="

# 1. Evaluate our own node file (a Nix Quine).
nix-instantiate --eval --strict --json "$ROOT/app/node.nix" > "$work/eval.json"
SELF_ID="$(jq -r .self "$work/eval.json")"
PEER_ID="$(jq -r .peer "$work/eval.json")"
echo "self: $SELF_ID"
echo "peer: $PEER_ID"

# -j, not -r: the rendered sources already end in a newline.
jq -j .selfSource "$work/eval.json" > "$work/node-self.nix"
jq -j .peerSource "$work/eval.json" > "$work/node-peer.nix"

# Quine sanity check: the source this image reconstructs for itself must be
# exactly the file it reconstructs it from.
cmp "$work/node-self.nix" "$ROOT/app/node.nix"
echo "self-render is byte-identical to /app/node.nix"

# 2. Reconstruct the peer's root filesystem.
#    Mirrors the rootfsFor derivation in default.nix: closure and /app are
#    identical between the two enclaves except for /app/node.nix.
user="$work/user"
rfs="$user/rootfs"
mkdir -p "$rfs/nix/store" "$rfs/app"
for p in $(cat "$ROOT/app/closure.txt"); do
  cp -r "$p" "$rfs/nix/store/"
done
cp "$ROOT/app/closure.txt" "$rfs/app/closure.txt"
cp "$ROOT/app/run" "$rfs/app/run"
cp "$work/node-peer.nix" "$rfs/app/node.nix"

# 3. Reconstruct the peer's user ramdisk.
#    Mirrors nitro.lib.mkUserRamdisk + nitro.lib.mkCpioArchive.
cp "@payload@/env" "$user/env"
cp "@payload@/cmd" "$user/cmd"
(cd "$rfs" && mkdir -p dev run sys var proc tmp || true)

# At build time the ramdisk gets packed from a Nix store path, which the store
# has canonicalised: no write bits anywhere, every mtime set to 1.
chmod -R a-w "$user"
find "$user" -exec touch -h --date=@1 {} +
(cd "$user" && find * .[^.*] -print0 | sort -z | cpio -o -H newc -R +0:+0 --reproducible --null | gzip -n > "$OUT/peer-user-initramfs.cpio.gz") 2> /dev/null

# 4. Rebuild the peer's EIF and measure it. Mirrors nitro.lib.mkEif.
cd "$work"
eif_build \
  --arch @arch@ \
  --kernel @payload@/kernel \
  --kernel_config @payload@/kernel-config \
  --cmdline "@cmdline@" \
  --ramdisk "@payload@/sys-initramfs-$PEER_ID.cpio.gz" \
  --ramdisk "$OUT/peer-user-initramfs.cpio.gz" \
  --name @eifName@ \
  --version @eifVersion@ \
  --build-tool='monzo-aws-nitro-util' --build-time='1970-01-01T00:00:00.000000+00:00' \
  --output "$OUT/peer.eif" >> log.txt
cat log.txt | tail -6 >> "$OUT/peer-pcr.json"

echo
echo "==[ reference PCRs for peer enclave $PEER_ID ]=="
cat "$OUT/peer-pcr.json"
echo
echo "compare against the peer's build-time pcr.json and its (non-debug) attestation document."

if [ "$HOLD" = "1" ]; then
  # keep the enclave alive so the console output can be read at leisure
  while true; do sleep 3600; done
fi
