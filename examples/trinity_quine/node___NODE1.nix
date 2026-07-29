# auto-generated mutually-referential attestation node -- do not edit
let
  __nixreflect_SELF__ = "__NODE1";
  __nixreflect_DATA__ = "{\"bodies\":{\"__NODE1\":\"# ========== BODY ========== \\nbuiltins.hashString \\\"sha256\\\" (__nixreflect_render__ \\\"__NODE2\\\")\\n\",\"__NODE2\":\"# ========== BODY ========== \\nbuiltins.hashString \\\"sha256\\\" (__nixreflect_render__ \\\"__NODE3\\\")\\n\",\"__NODE3\":\"# ========== BODY ========== \\nbuiltins.hashString \\\"sha256\\\" (__nixreflect_render__ \\\"__NODE1\\\")\\n\"},\"framework\":\"  # ========== NixReflect FRAMEWORK ==========\\n\\n  __nixreflect_blob__ = builtins.fromJSON __nixreflect_DATA__;\\n\\n  # Nix double-quoted string literal for `s`; mirrors nixreflect.transpiler.nix_str.\\n  __nixreflect_nix_str__ = s: \\\"\\\\\\\"\\\" + builtins.replaceStrings\\n    [ \\\"\\\\\\\\\\\" \\\"\\\\\\\"\\\" \\\"\\\\\${\\\" ] [ \\\"\\\\\\\\\\\\\\\\\\\" \\\"\\\\\\\\\\\\\\\"\\\" \\\"\\\\\\\\\\\\\${\\\" ] s + \\\"\\\\\\\"\\\";\\n\\n  # Exact source code (string) of node `target`, reconstructed from embedded data.\\n  __nixreflect_render__ = target:\\n    __nixreflect_blob__.header\\n    + \\\"  __nixreflect_SELF__ = \\\" + __nixreflect_nix_str__ target + \\\";\\\\n\\\"\\n    + \\\"  __nixreflect_DATA__ = \\\" + __nixreflect_nix_str__ __nixreflect_DATA__ + \\\";\\\\n\\\"\\n    + \\\"\\\\n\\\"\\n    + __nixreflect_blob__.framework + \\\"\\\\n\\\"\\n    + __nixreflect_blob__.bodies.\${target};\\n\\n  __nixreflect_node_ids__ = __nixreflect_blob__.nodes;\\n\\n  __nixreflect_self_id__ = __nixreflect_SELF__;\\nin\",\"header\":\"# auto-generated mutually-referential attestation node -- do not edit\\nlet\\n\",\"nodes\":[\"__NODE1\",\"__NODE2\",\"__NODE3\"]}";

  # ========== NixReflect FRAMEWORK ==========

  __nixreflect_blob__ = builtins.fromJSON __nixreflect_DATA__;

  # Nix double-quoted string literal for `s`; mirrors nixreflect.transpiler.nix_str.
  __nixreflect_nix_str__ = s: "\"" + builtins.replaceStrings
    [ "\\" "\"" "\${" ] [ "\\\\" "\\\"" "\\\${" ] s + "\"";

  # Exact source code (string) of node `target`, reconstructed from embedded data.
  __nixreflect_render__ = target:
    __nixreflect_blob__.header
    + "  __nixreflect_SELF__ = " + __nixreflect_nix_str__ target + ";\n"
    + "  __nixreflect_DATA__ = " + __nixreflect_nix_str__ __nixreflect_DATA__ + ";\n"
    + "\n"
    + __nixreflect_blob__.framework + "\n"
    + __nixreflect_blob__.bodies.${target};

  __nixreflect_node_ids__ = __nixreflect_blob__.nodes;

  __nixreflect_self_id__ = __nixreflect_SELF__;
in
# ========== BODY ========== 
builtins.hashString "sha256" (__nixreflect_render__ "__NODE2")
