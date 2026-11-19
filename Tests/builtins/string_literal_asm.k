// Building a two-word string from a literal is two constants and no call:
// the address of the literal's bytes and the meta word, here 6 << 3 | 1.
// The literal's object is in a read-only section.

fn lit() -> string {
    return "h\u00e9llo"
}

fn main() -> i32 {
    return (lit().size() - 6) as i32
}

// --- lit wiring ---
// REQUIRES: host-x86_64
// RUN: rm -rf %t.dir && mkdir -p %t.dir && cd %t.dir
// RUN: cd %t.dir && %kairo %s -O2 -S -o %t.dir/out.s
// RUN: %FileCheck %s --input-file=%t.dir/out.s
// CHECK-LABEL: 3litEv:
// CHECK-NOT:   call
// CHECK:       __kairo_slit_6_
// CHECK:       $49
// CHECK-NOT:   call
// CHECK:       ret
// CHECK:       .section{{.*}}.rodata.__kairo_slit_6_
