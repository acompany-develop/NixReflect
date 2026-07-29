{
  description = "NixReflect -- a transpiler for mutually-referential reflective programming in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # NOTE: nitro-util's own nixpkgs pin is deliberately NOT overridden with
    # `follows`: the mutual_quine_ne example takes every tool that ends up
    # inside the enclaves from nitro-util's pkgs, so the binaries that pack the
    # ramdisks at build time and the binaries that re-pack them inside the
    # enclaves are the exact same store paths.
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
          mq = import ./examples/mutual_quine_ne {
            nitro = nitro-util.lib.${system};
            eifBuild = nitro-util.packages.${system}.eif_build;
            eifInit = nitro-util.packages.${system}.eif-init;
          };
        in
        {
          packages = {
            mutual-quine-ne-nodes = mq.nodes;
            mutual-quine-ne-eif1 = mq.eifs.node1;
            mutual-quine-ne-eif2 = mq.eifs.node2;
          };
          checks = {
            mutual-quine-ne-verify-1-rebuilds-2 = mq.verify.node1;
            mutual-quine-ne-verify-2-rebuilds-1 = mq.verify.node2;
          };
        }));
}
