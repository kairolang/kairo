// A function specialization may be written in another module than its
// primary (generics.mdx, Function specializations). Every TU of the
// program that declares the primary declares the specialization too, so a
// TU that calls `pick<u8>()` without importing the specializing module
// still runs the specialization, as does the TU of the primary. A record
// specialization stays in its primary's module (R042E): a record is
// extended instead.

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/inputs/fn_spec_other && { %kairo bad.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: bad.k:5:{{[0-9]+}}: error [R042E]: 'Box' is declared as a specialization, but no primary template named 'Box' is visible here
// BAD-NOT: error

// RUN: cd %S/inputs/fn_spec_other && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: cd %S/inputs/fn_spec_other && %kairo main.k -o %t.d/main --cache-dir %t.d/c
// RUN: %t.d/main
