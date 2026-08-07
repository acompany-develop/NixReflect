# NixReflect mutual quine on AWS Nitro Enclaves -- SHA-384 edition.
#
# Builds two enclave images that differ in exactly one file, /app/node.nix.
# At runtime each enclave evaluates its quine node, reconstructs the *peer's*
# node.nix source from data embedded in itself alone, and prints its SHA-384
# digest. Unlike the mutual_quine_ne_pcrs sibling, nothing is rebuilt inside
# the enclave -- no eif_build, no payload of EIF build inputs, far less memory
# -- so this isolates the Kleene fixed point on Nitro hardware from the
# reproducible-build machinery that turns source digests into PCRs.
{ nitro, eifInit, pkgs ? nitro.pkgs }:
# `pkgs` defaults to nitro-util's own nixpkgs, matching mutual_quine_ne_pcrs;
# here that is mere consistency (nothing is re-packed inside the enclave).
let
  arch = pkgs.stdenv.hostPlatform.uname.processor;

  eifName = "mutual-quine-ne-sha";
  eifVersion = "0.1.0";
  cmdline = "reboot=k panic=30 pci=off nomodules console=ttyS0 random.trust_cpu=on root=/dev/ram0";

  # transpile the template with NixReflect at build time (>= 3.12 for PEP 695)
  nodes = pkgs.runCommand "nixreflect-mq-ne-sha-nodes"
    { nativeBuildInputs = [ pkgs.python312 ]; } ''
    export PYTHONPATH=${../../src}
    mkdir -p $out
    python3 -m nixreflect ${./template.json} $out
  '';

  nodeId1 = "__ENCLAVE1";
  nodeId2 = "__ENCLAVE2";

  # nothing in the bootstrap ramdisk is node-specific (no in-enclave rebuild,
  # so no need to pick a peer ramdisk by /node-id): one ramdisk serves both
  # images, and the two enclaves share PCR1
  sysRamdisk = nitro.mkSysRamdisk {
    init = eifInit + "/bin/init";
    nsmKo = nitro.blobs.${arch}.nsmKo;
  };

  # every tool the in-enclave evaluation needs, identical for both enclaves:
  # nix evaluates the quine, jq picks fields out of the eval JSON, coreutils
  # provides sha384sum, diffutils provides cmp for the self-render check
  appEnv = pkgs.buildEnv {
    name = "mq-ne-sha-tools";
    paths = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.jq
      pkgs.nix
    ];
  };

  env = "PATH=${appEnv}/bin";
  entrypoint = "/app/run";

  runScript = pkgs.writeShellScript "mq-ne-sha-run" (builtins.replaceStrings
    [ "@appEnv@" ]
    [ "${appEnv}" ]
    (builtins.readFile ./run.sh));

  closureList = pkgs.closureInfo { rootPaths = [ appEnv ]; };

  rootfsFor = label: nodeFile: pkgs.runCommand "mq-ne-sha-rootfs-${label}" { } ''
    mkdir -p $out/nix/store $out/app
    for p in $(cat ${closureList}/store-paths); do
      cp -r $p $out/nix/store/
    done
    cp ${runScript} $out/app/run
    cp ${nodeFile} $out/app/node.nix
  '';

  eifFor = rootfs: nitro.mkEif {
    name = eifName;
    version = eifVersion;
    inherit arch cmdline;
    kernel = nitro.blobs.${arch}.kernel;
    kernelConfig = nitro.blobs.${arch}.kernelConfig;
    ramdisks = [
      sysRamdisk
      (nitro.mkUserRamdisk { inherit env entrypoint rootfs; })
    ];
  };

  rootfs1 = rootfsFor "node1" "${nodes}/node_${nodeId1}.nix";
  rootfs2 = rootfsFor "node2" "${nodes}/node_${nodeId2}.nix";
  eif1 = eifFor rootfs1;
  eif2 = eifFor rootfs2;

  # Re-run the exact enclave entrypoint against a node's pristine rootfs and
  # demand that the source it reconstructs for its peer -- and the SHA-384
  # digest it prints -- match the peer's actual node file. This proves the
  # mutual-quine property without Nitro hardware.
  verifyFor = label: rootfs: peerNodeFile: pkgs.runCommand "mq-ne-sha-verify-${label}" { } ''
    export NIXREFLECT_ROOT=${rootfs}
    export NIXREFLECT_OUT=$PWD/out
    export NIXREFLECT_HOLD=0
    ${runScript}

    echo "--- comparing the runtime-reconstructed peer source against ${peerNodeFile}"
    cmp out/peer-node.nix ${peerNodeFile}
    expected=$(sha384sum ${peerNodeFile} | cut -d" " -f1)
    [ "$(cat out/peer-sha384)" = "$expected" ]
    echo "peer source and SHA-384 digest match."
    touch $out
  '';
in
{
  inherit nodes appEnv runScript;
  rootfs = { node1 = rootfs1; node2 = rootfs2; };
  eifs = { node1 = eif1; node2 = eif2; };
  verify = {
    node1 = verifyFor "node1" rootfs1 "${nodes}/node_${nodeId2}.nix";
    node2 = verifyFor "node2" rootfs2 "${nodes}/node_${nodeId1}.nix";
  };
}
