// SC136E under a module.k: an unmarked function there is `prot` by
// default, and `prot` is not `priv`, so it reaches the module's C++ header
// and may not carry a calling convention. A written `priv` still may.
// Outside a module the same unmarked function is `priv`: callconv_boundary.k.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/callconv_mod && { %kairo lib.k --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK-DAG: lib.k:5:{{[0-9]+}}: error [SC136E]: '@preserve_most' cannot cross the C/C++ boundary: GCC cannot call it
// CHECK-DAG: lib.k:9:{{[0-9]+}}: error [SC136E]: '@preserve_most' cannot cross the C/C++ boundary
