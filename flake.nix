{
  description = "NixReflect -- a transpiler for mutually-referential reflective programming in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # NOTE: nitro-util's own nixpkgs pin is deliberately NOT overridden with
    # `follows`: the mutual_quine_ne_{sha,pcrs} examples take every tool that
    # ends up inside the enclaves from nitro-util's pkgs, so the binaries that
    # pack the ramdisks at build time and the binaries that re-pack them
    # inside the enclaves (mutual_quine_ne_pcrs) are the exact same store
    # paths.
    nitro-util.url = "github:monzo/aws-nitro-util";
  };

  outputs = { self, nixpkgs, flake-utils, nitro-util }:
    nixpkgs.lib.recursiveUpdate

      # the transpiler itself runs anywhere
      (flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nixreflect = pkgs.python3Packages.buildPythonApplication {
            pname = "nixreflect";
            version = "0.1.0";
            pyproject = true;
            src = ./.;
            build-system = [ pkgs.python3Packages.hatchling ];
          };
        in
        {
          packages.default = nixreflect;
          packages.nixreflect = nixreflect;
          devShells.default = pkgs.mkShell { packages = [ pkgs.python3 ]; };
          # transpile every example and assert its quine property end to end
          checks = import ./examples/checks.nix { inherit pkgs; };
        }))

      # EIFs boot Linux kernels; build them on (or via a remote builder for)
      # the Linux system matching the enclave's architecture
      (flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
        let
          nitro = nitro-util.lib.${system};
          eifInit = nitro-util.packages.${system}.eif-init;
          # in-enclave SHA-384 of the peer's source only; no rebuild inside
          mqSha = import ./examples/mutual_quine_ne_sha {
            inherit nitro eifInit;
          };
          # full in-enclave rebuild of the peer's EIF, yielding its PCRs
          mqPcrs = import ./examples/mutual_quine_ne_pcrs {
            inherit nitro eifInit;
            eifBuild = nitro-util.packages.${system}.eif_build;
          };
        in
        {
          packages = {
            mutual-quine-ne-sha-nodes = mqSha.nodes;
            mutual-quine-ne-sha-eif1 = mqSha.eifs.node1;
            mutual-quine-ne-sha-eif2 = mqSha.eifs.node2;
            mutual-quine-ne-pcrs-nodes = mqPcrs.nodes;
            mutual-quine-ne-pcrs-eif1 = mqPcrs.eifs.node1;
            mutual-quine-ne-pcrs-eif2 = mqPcrs.eifs.node2;
          };
          checks = {
            mutual-quine-ne-sha-verify-1-hashes-2 = mqSha.verify.node1;
            mutual-quine-ne-sha-verify-2-hashes-1 = mqSha.verify.node2;
            mutual-quine-ne-pcrs-verify-1-rebuilds-2 = mqPcrs.verify.node1;
            mutual-quine-ne-pcrs-verify-2-rebuilds-1 = mqPcrs.verify.node2;
          };
        }));
}
