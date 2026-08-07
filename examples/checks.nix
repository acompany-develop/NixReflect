# E2E checks for the transpiler examples. For each template:
#   1. transpile it with the in-repo transpiler,
#   2. assert the output is byte-identical to the committed node files
#      (drift detection),
#   3. evaluate the emitted nodes with nix-instantiate and assert the
#      quine property they claim (self-reproduction / peer digests).
# The mutual_quine_ne_{sha,pcrs} examples have their own, much stronger
# checks in ./mutual_quine_ne_sha/default.nix (peer source digest) and
# ./mutual_quine_ne_pcrs/default.nix (EIF reconstruction).
{ pkgs }:
let
  # >= 3.12 for PEP 695; keep in sync with mutual_quine_ne_{sha,pcrs}/default.nix
  transpiled = name: pkgs.runCommand "nixreflect-${name}-transpiled"
    { nativeBuildInputs = [ pkgs.python312 ]; } ''
    export PYTHONPATH=${../src}
    mkdir -p $out
    python3 -m nixreflect ${./. + "/${name}/template.json"} $out
  '';

  # nix-instantiate performs pure evaluation only, but still wants writable
  # state and cache locations (same trick as mutual_quine_ne_pcrs/run.sh)
  check = name: script: pkgs.runCommand "nixreflect-e2e-${name}"
    { nativeBuildInputs = [ pkgs.nix pkgs.jq ]; } ''
    export HOME="$TMPDIR/home" XDG_CACHE_HOME="$TMPDIR/cache" \
      NIX_STATE_DIR="$TMPDIR/nix/state" NIX_LOG_DIR="$TMPDIR/nix/log" \
      NIX_CONF_DIR="$TMPDIR/nix/conf"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" "$TMPDIR/nix/state" \
      "$TMPDIR/nix/log" "$TMPDIR/nix/conf"
    evalRaw() { nix-instantiate --eval --strict --json "$1" | jq -j .; }
    digest() { sha256sum "$1" | cut -d" " -f1; }
    ${script}
    touch $out
  '';

  driftCheck = name: pkgs.runCommand "nixreflect-drift-${name}" { } ''
    cd ${transpiled name}
    for f in *; do
      echo "comparing $f against the committed copy"
      diff "$f" ${./. + "/${name}"}/"$f"
    done
    touch $out
  '';
in
{
  # the node evaluates to its own exact source
  example-quine = check "quine" ''
    d=${transpiled "quine"}
    evalRaw "$d/node___NODE.nix" | cmp - "$d/node___NODE.nix"
  '';

  # each node evaluates to the SHA-256 digest of its peer's source
  example-mutual-quine = check "mutual-quine" ''
    d=${transpiled "mutual_quine"}
    [ "$(evalRaw $d/node___NODE1.nix)" = "$(digest $d/node___NODE2.nix)" ]
    [ "$(evalRaw $d/node___NODE2.nix)" = "$(digest $d/node___NODE1.nix)" ]
  '';

  # three nodes in a cycle: 1 -> 2 -> 3 -> 1
  example-trinity-quine = check "trinity-quine" ''
    d=${transpiled "trinity_quine"}
    [ "$(evalRaw $d/node___NODE1.nix)" = "$(digest $d/node___NODE2.nix)" ]
    [ "$(evalRaw $d/node___NODE2.nix)" = "$(digest $d/node___NODE3.nix)" ]
    [ "$(evalRaw $d/node___NODE3.nix)" = "$(digest $d/node___NODE1.nix)" ]
  '';

  # the committed example outputs are exactly what the transpiler emits today
  transpile-drift-quine = driftCheck "quine";
  transpile-drift-mutual-quine = driftCheck "mutual_quine";
  transpile-drift-trinity-quine = driftCheck "trinity_quine";
}
