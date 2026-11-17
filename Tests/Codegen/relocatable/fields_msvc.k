// The rule of fields.k does not depend on the target: the same records are
// accepted and the same ones rejected for the Microsoft C++ ABI, whose own
// notion of a record passed as its bytes differs (it refuses a move-only
// C++ record and admits a small one with a destructor).

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: { %kairo %S/fields.k --type-check-only -DBAD --target=x86_64-windows-msvc 2>&1 || true; } | %FileCheck %S/fields.k --check-prefix=ERR
// RUN: %kairo %S/fields.k --type-check-only --target=x86_64-windows-msvc 2>&1 | %FileCheck %S/fields.k --check-prefix=OK --allow-empty
// RUN: %kairo %S/fields.k -c -o %t.obj --cache-dir %t.d --target=x86_64-windows-msvc 2>&1 | %FileCheck %S/fields.k --check-prefix=OK --allow-empty
