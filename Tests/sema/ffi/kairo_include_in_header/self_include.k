ffi "c++" import "self_include.h"

// The header imported above includes this very file. Clang read it as
// C++ (CL001E errors pointing into this file), lost the header's
// declarations and Sema cascaded (R020E on every use). Now the include is
// skipped, the one error is R070E at the header's line, and buf_reserve
// still imports: the call below resolves.
fn grow(a: usize) {
    buf_reserve(a)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      self_include.h:2:10: error [R070E]: a C or C++ header imported from Kairo cannot include the Kairo source file 'self_include.k' (it is the file that imports this header)
// CHECK-NEXT: self_include.k:1:18: note [I900N]: 'self_include.h' is imported here
// CHECK-NEXT: note [R070N]: the header has to declare what it uses itself; C++ reaches Kairo declarations through kcc, where a C++ source file can #include a .k file, or through the headers `kairo --emit-headers <dir>` writes
// CHECK-NOT:  {{error|warning}} [
