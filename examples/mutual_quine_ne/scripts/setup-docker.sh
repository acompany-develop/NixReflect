#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Install Docker on Ubuntu from the distro archive (docker.io).
# Docker is a build-time dependency of nitro-cli >= 1.4: `make nitro-cli`
# compiles the CLI inside a container.
#
# Idempotent: safe to re-run. Adapted from
# https://github.com/acompany-develop/Humane-RAFW-NE/blob/main/scripts/setup-docker.sh

set -euo pipefail

if command -v docker > /dev/null; then
	echo "docker is already installed: $(docker --version)"
else
	sudo apt-get update
	sudo apt-get install -y docker.io
fi

sudo systemctl enable --now docker

# let the invoking user run docker without sudo (takes effect on next login)
if ! id -nG "$USER" | grep -qw docker; then
	sudo usermod -aG docker "$USER"
	echo "added $USER to the docker group -- log out and back in for it to apply"
fi

docker --version
