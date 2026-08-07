#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Host setup for AWS Nitro Enclaves on Ubuntu (tested on Ubuntu 26.04 on a
# Nitro-Enclaves-enabled EC2 instance). Installs the nitro_enclaves kernel
# driver, nitro-cli v1.4.5 (pinned by commit hash) and the enclave resource
# allocator, and makes all of it survive reboots.
#
# Idempotent: safe to re-run; completed steps are skipped.
# Adapted from
# https://github.com/acompany-develop/Humane-RAFW-NE/blob/main/scripts/setup-nitro-cli.sh
#
# Why a shell script and not Nix: the host side is kernel-module + udev +
# systemd state on a foreign (non-NixOS) distro, which Nix cannot manage
# declaratively. Everything downstream of this script -- building the EIFs and
# their in-enclave reconstruction -- is pure Nix; see ../default.nix.
#
# Tunables (env vars):
#   ALLOCATOR_MEMORY_MIB  memory reserved for enclaves (default 8192 -- the
#                         mutual_quine_ne_pcrs enclaves rebuild an EIF in RAM;
#                         mutual_quine_ne_sha gets by with far less, e.g. 2048)
#   ALLOCATOR_CPU_COUNT   CPUs reserved for enclaves   (default 2)

set -euo pipefail

NITRO_CLI_VERSION="1.4.5"
NITRO_CLI_COMMIT="18a5f6f35f110c0f235f193ae3caff9434d64ee1" # v1.4.5
ALLOCATOR_MEMORY_MIB="${ALLOCATOR_MEMORY_MIB:-8192}"
ALLOCATOR_CPU_COUNT="${ALLOCATOR_CPU_COUNT:-2}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
KERNEL_VERSION="$(uname -r)"

# --- 1. build dependencies -------------------------------------------------
sudo apt-get update
sudo apt-get install -y build-essential git jq

# docker is required since nitro-cli v1.4: `make nitro-cli` builds in a container
if [ -x "$SCRIPT_DIR/setup-docker.sh" ]; then
	"$SCRIPT_DIR/setup-docker.sh"
else
	command -v docker > /dev/null || sudo apt-get install -y docker.io
	sudo systemctl enable --now docker
fi

# --- 2. nitro_enclaves kernel driver ----------------------------------------
# Recent Ubuntu kernels ship the driver in-tree; older AWS kernels carry it in
# linux-modules-extra. Building it out of tree is a last resort.
if ! sudo modprobe nitro_enclaves 2> /dev/null; then
	sudo apt-get install -y linux-modules-extra-aws \
		|| sudo apt-get install -y "linux-modules-extra-$KERNEL_VERSION" \
		|| true
	sudo modprobe nitro_enclaves 2> /dev/null || NEED_DRIVER_BUILD=1
fi

# load the driver on every boot
echo nitro_enclaves | sudo tee /etc/modules-load.d/nitro_enclaves.conf > /dev/null

# --- 3. nitro-cli v1.4.5 (pinned) -------------------------------------------
installed_version="$(nitro-cli --version 2> /dev/null | awk '{print $3}' || true)"
if [ "$installed_version" = "$NITRO_CLI_VERSION" ] && [ -z "${NEED_DRIVER_BUILD:-}" ]; then
	echo "nitro-cli $NITRO_CLI_VERSION already installed; skipping build"
else
	# Rust toolchain (host-side vsock-proxy build)
	if ! command -v cargo > /dev/null && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
	fi
	# rustup's env script references unset vars; disable -u around it
	set +u; source "$HOME/.cargo/env"; set -u

	if [ ! -d "$HOME/aws-nitro-enclaves-cli" ]; then
		git clone https://github.com/aws/aws-nitro-enclaves-cli "$HOME/aws-nitro-enclaves-cli"
	fi
	pushd "$HOME/aws-nitro-enclaves-cli"
	git fetch --all --quiet
	git checkout --quiet "$NITRO_CLI_COMMIT"

	# out-of-tree driver build, only as a last resort (step 2 failed)
	if [ -n "${NEED_DRIVER_BUILD:-}" ]; then
		pushd drivers/virt/nitro_enclaves
		sudo make
		sudo install -D nitro_enclaves.ko \
			"/usr/lib/modules/$KERNEL_VERSION/extra/nitro_enclaves/nitro_enclaves.ko"
		sudo depmod -a
		sudo modprobe nitro_enclaves
		popd
	fi

	if [ "$installed_version" != "$NITRO_CLI_VERSION" ]; then
		sudo make nitro-cli
		sudo make vsock-proxy
		sudo make NITRO_CLI_INSTALL_DIR=/ install
	fi
	popd
fi

# --- 4. device permissions & runtime directories ----------------------------
# Upstream's `nitro-cli-config -i` does this interactively; do it declaratively
# so it holds across reboots.
getent group ne > /dev/null || sudo groupadd ne
id -nG "$USER" | grep -qw ne || {
	sudo usermod -aG ne "$USER"
	echo "added $USER to the ne group -- log out and back in for it to apply"
}

# /dev/nitro_enclaves is root-only by default
sudo tee /etc/udev/rules.d/99-nitro-enclaves.rules > /dev/null << 'EOF'
SUBSYSTEM=="misc", KERNEL=="nitro_enclaves", GROUP="ne", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=nitro_enclaves 2> /dev/null || true

# /run is tmpfs: without this entry nitro-cli fails with E07 after every reboot
sudo tee /etc/tmpfiles.d/nitro_enclaves.conf > /dev/null << 'EOF'
d /run/nitro_enclaves     2775 root ne -
d /var/log/nitro_enclaves 2775 root ne -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/nitro_enclaves.conf

# --- 5. enclave resource allocator ------------------------------------------
sudo sed -i \
	-e "s/^memory_mib:.*/memory_mib: $ALLOCATOR_MEMORY_MIB/" \
	-e "s/^cpu_count:.*/cpu_count: $ALLOCATOR_CPU_COUNT/" \
	/etc/nitro_enclaves/allocator.yaml
sudo systemctl enable --now nitro-enclaves-allocator.service
sudo systemctl restart nitro-enclaves-allocator.service

# --- 6. smoke test -----------------------------------------------------------
nitro-cli --version
sudo nitro-cli describe-enclaves > /dev/null
echo
echo "OK: nitro-cli $NITRO_CLI_VERSION ready; allocator reserves ${ALLOCATOR_MEMORY_MIB} MiB / ${ALLOCATOR_CPU_COUNT} CPUs."
echo "Run 'newgrp ne' (or re-login) to use nitro-cli without sudo."
