// A generic function or a generic class's method whose instance is homed in
// another module is inlinable at -O2 where it is used, as a C++ template in
// a header is: the importing module's `extern template` keeps the one
// definition in the home module, and the definition is C++ `inline`, so
// clang still instantiates the body here for its optimizer.
import helper::*

pub fn use_twice(v: u64) -> u64 { return twice<u64>(v) }
pub fn use_get(b: *Box<u64>) -> u64 { return b->get() }

fn main() -> i32 {
    var b = Box<u64>()
    b.v = 21
    return (use_twice(home(&b)) - 42) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --emit asm --emit-scope=inputs -c --target x86_64-linux-gnu -o %t.d/main.s
// RUN: %FileCheck %s < %t.d/main.s
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}main{{_?}}9use_twice{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_ZN6helper
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}main{{_?}}7use_get{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_ZN6helper
// CHECK: .cfi_endproc

// REQUIRES: clang
// RUN: rm -rf %t.run
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.run
// RUN: %t.exe
