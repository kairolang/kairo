// What a C++ file sees of an included `.k` follows Kairo's visibility
// (decided 2026-11-08): `pub` always, `prot` only from a C++ file of the
// declaring file's module (under the same nearest module.k), `priv` never.
// An unmarked declaration under a module.k is `prot`.
//
// Inputs/kvis/mod/ holds module.k and api.k (open_fn pub, mod_fn prot,
// file_fn priv, bare_fn unmarked). mod/inside.cc is in the module: pub,
// prot and the unmarked one link and run (1 + 2 + 8); priv is not
// declared. outside.cc is not: only pub is declared there.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// RUN: cd %S/Inputs/kvis && %kcc mod/inside.cc mod/api.k -o %t.d/in && %t.d/in; test $? -eq 11
// RUN: cd %S/Inputs/kvis && %kcc outside.cc mod/api.k -o %t.d/out && %t.d/out; test $? -eq 1

// RUN: cd %S/Inputs/kvis && { %kcc -DUSE_PRIV mod/inside.cc mod/api.k -o %t.d/x 2>&1 || true; } | %FileCheck %s --check-prefix=INPRIV
// INPRIV: inside.cc:7:22: error [CL001E]: no member named 'file_fn' in namespace 'mod::api'
// RUN: cd %S/Inputs/kvis && { %kcc -DUSE_PROT outside.cc mod/api.k -o %t.d/x 2>&1 || true; } | %FileCheck %s --check-prefix=OUTPROT
// OUTPROT: outside.cc:7:22: error [CL001E]: no member named 'mod_fn' in namespace 'mod::api'
// RUN: cd %S/Inputs/kvis && { %kcc -DUSE_BARE outside.cc mod/api.k -o %t.d/x 2>&1 || true; } | %FileCheck %s --check-prefix=OUTBARE
// OUTBARE: outside.cc:9:22: error [CL001E]: no member named 'bare_fn' in namespace 'mod::api'
// RUN: cd %S/Inputs/kvis && { %kcc -DUSE_PRIV outside.cc mod/api.k -o %t.d/x 2>&1 || true; } | %FileCheck %s --check-prefix=OUTPRIV
// OUTPRIV: outside.cc:11:22: error [CL001E]: no member named 'file_fn' in namespace 'mod::api'
