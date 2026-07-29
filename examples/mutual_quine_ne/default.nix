# NixReflect mutual quine on AWS Nitro Enclaves.
#
# Builds two enclave images whose node-specific parts are /app/node.nix (user
# ramdisk) and /node-id (bootstrap ramdisk); every other build input is
# byte-identical between them, so each enclave can deterministically
# reconstruct the *other* image -- and therefore its reference PCRs -- from
# data embedded in itself alone.
{ nitro, eifBuild, eifInit, pkgs ? nitro.pkgs }:
# `pkgs` defaults to nitro-util's own nixpkgs so that the tools packed *into*
# the enclaves are the very same store paths aws-nitro-util uses to pack the
# ramdisks at build time -- a prerequisite for the in-enclave rebuild to be
# byte-exact.
let
  arch = pkgs.stdenv.hostPlatform.uname.processor;

  eifName = "mutual-quine-ne";
  eifVersion = "0.1.0";
  # must stay identical between mkEif below and run.sh's runtime rebuild
  cmdline = "reboot=k panic=30 pci=off nomodules console=ttyS0 random.trust_cpu=on root=/dev/ram0";

  # transpile the template with NixReflect at build time (>= 3.12 for PEP 695)
  nodes = pkgs.runCommand "nixreflect-mq-ne-nodes"
    { nativeBuildInputs = [ pkgs.python312 ]; } ''
    export PYTHONPATH=${../../src}
    mkdir -p $out
    python3 -m nixreflect ${./template.json} $out
  '';

  nodeId1 = "__ENCLAVE1";
  nodeId2 = "__ENCLAVE2";

  # bootstrap ramdisk (measured into PCR1): init + nsm.ko as in
  # nitro.mkSysRamdisk, plus /node-id to make the measurement node-specific
  sysRamdiskFor = nodeId: nitro.mkCpioArchive {
    name = "bootstrap-initramfs-${nodeId}";
    src = pkgs.runCommand "bootstrap-initramfs-${nodeId}-fs" { } ''
      mkdir -p $out/dev
      cp ${nitro.blobs.${arch}.nsmKo} $out/nsm.ko
      cp ${eifInit + "/bin/init"} $out/init
      echo ${nodeId} > $out/node-id
    '';
  };
  sysRamdisk1 = sysRamdiskFor nodeId1;
  sysRamdisk2 = sysRamdiskFor nodeId2;

  # every tool the in-enclave reconstruction needs, identical for both enclaves
  appEnv = pkgs.buildEnv {
    name = "mq-ne-tools";
    paths = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.diffutils
      pkgs.cpio
      pkgs.gzip
      pkgs.jq
      pkgs.nix
      eifBuild
    ];
  };

  env = "PATH=${appEnv}/bin";
  entrypoint = "/app/run";

  # byte-copies of every EIF build input, identical for both enclaves (hence
  # both bootstrap ramdisks); the runtime rebuild must never depend on a
  # peer-specific store path
  payload = pkgs.runCommand "mq-ne-payload" { } ''
    mkdir -p $out
    cp ${nitro.blobs.${arch}.kernel} $out/kernel
    cp ${nitro.blobs.${arch}.kernelConfig} $out/kernel-config
    cp ${sysRamdisk1} $out/sys-initramfs-${nodeId1}.cpio.gz
    cp ${sysRamdisk2} $out/sys-initramfs-${nodeId2}.cpio.gz
    cp ${pkgs.writeText "mq-ne-env" env} $out/env
    cp ${pkgs.writeText "mq-ne-cmd" entrypoint} $out/cmd
  '';

  runScript = pkgs.writeShellScript "mq-ne-run" (builtins.replaceStrings
    [ "@appEnv@" "@payload@" "@arch@" "@cmdline@" "@eifName@" "@eifVersion@" ]
    [ "${appEnv}" "${payload}" arch cmdline eifName eifVersion ]
    (builtins.readFile ./run.sh));

  # /app/closure.txt lists every store path inside the rootfs. The list cannot
  # itself live in the store (a store path cannot contain its own hash), so it
  # is copied out to a plain file.
  closureList = pkgs.closureInfo { rootPaths = [ appEnv payload ]; };

  # run.sh step 2 mirrors this derivation -- keep them in sync
  rootfsFor = label: nodeFile: pkgs.runCommand "mq-ne-rootfs-${label}" { } ''
    mkdir -p $out/nix/store $out/app
    for p in $(cat ${closureList}/store-paths); do
      cp -r $p $out/nix/store/
    done
    cp ${closureList}/store-paths $out/app/closure.txt
    cp ${runScript} $out/app/run
    cp ${nodeFile} $out/app/node.nix
  '';

  eifFor = sysRamdisk: rootfs: nitro.mkEif {
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
  eif1 = eifFor sysRamdisk1 rootfs1;
  eif2 = eifFor sysRamdisk2 rootfs2;

  # Re-run the exact enclave entrypoint against a node's pristine rootfs and
  # demand that the EIF it reconstructs for its peer matches the EIF Nix built
  # for that peer. This proves the mutual-quine property without Nitro hardware.
  verifyFor = label: rootfs: peerEif: pkgs.runCommand "mq-ne-verify-${label}" { } ''
    export NIXREFLECT_ROOT=${rootfs}
    export NIXREFLECT_OUT=$PWD/out
    export NIXREFLECT_HOLD=0
    ${runScript}

    echo "--- comparing runtime-reconstructed PCRs against ${peerEif}/pcr.json"
    diff out/peer-pcr.json ${peerEif}/pcr.json
    echo "PCRs match."
    if cmp -s out/peer.eif ${peerEif}/image.eif; then
      echo "EIF is even byte-for-byte identical."
    else
      echo "note: EIF bytes differ (unmeasured metadata only); the PCRs above are what count."
    fi
    touch $out
  '';
in
{
  inherit nodes appEnv payload runScript;
  rootfs = { node1 = rootfs1; node2 = rootfs2; };
  eifs = { node1 = eif1; node2 = eif2; };
  verify = {
    node1 = verifyFor "node1" rootfs1 eif2;
    node2 = verifyFor "node2" rootfs2 eif1;
  };
}
