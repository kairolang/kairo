// Scripts/Migration/const_value_params.py: generic value parameters
// `<const N: T>` become `<eval N: T>` (TICKETS: "Compiler/ spells generic
// value parameters"). The fixture holds several parameters in one list,
// type parameters mixed in, a member template nested in a
// generic class, odd spacing, and the shapes that must stay: a comment and
// a string naming the old form, and a `const` function parameter.
//
// Three properties, each against the same expected file:
//   1. the script's output is the expected file;
//   2. a second run rewrites nothing (idempotent);
//   3. accepting every fix-it the compiler offers on the fixture (S001E,
//      DeclParse.k's `const` -> `eval`) gives the same file, byte for byte,
//      so the script and the fix-it cannot drift apart.
// Plus the script's own table (--selftest).

// --- lit wiring ---
// RUN: rm -rf %t && mkdir -p %t/fix
// RUN: cp %S/Inputs/const_value_params/gen.k %t/gen.k
// RUN: python3 %S/../../../Scripts/Migration/const_value_params.py %t --apply | %FileCheck %s --check-prefix=APPLY
// APPLY: 6 site(s) in 1 file(s) of 1 scanned
// RUN: diff %t/gen.k %S/Inputs/const_value_params/gen.k.expected
// RUN: python3 %S/../../../Scripts/Migration/const_value_params.py %t | %FileCheck %s --check-prefix=AGAIN
// AGAIN: 0 site(s) in 0 file(s) of 1 scanned
//
// RUN: cp %S/Inputs/const_value_params/gen.k %t/fix/gen.k
// RUN: { %kairo %t/fix/gen.k --type-check-only 2>&1 || true; } > %t/fix/diags.txt
// RUN: %FileCheck %s --check-prefix=FIXDIAG --implicit-check-not="error [" --implicit-check-not="warning [" < %t/fix/diags.txt
// FIXDIAG-COUNT-6: error [S001E]: a generic value parameter is written 'eval N: T', not 'const N: T'
// RUN: python3 %S/Inputs/const_value_params/apply_fixits.py %t/fix/diags.txt %t/fix/gen.k | %FileCheck %s --check-prefix=APPLIED
// APPLIED: 6 fix-it(s) applied
// RUN: diff %t/fix/gen.k %S/Inputs/const_value_params/gen.k.expected
//
// RUN: python3 %S/../../../Scripts/Migration/const_value_params.py --selftest | %FileCheck %s --check-prefix=SELF
// SELF: 16/16 ok
