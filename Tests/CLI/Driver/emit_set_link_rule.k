// Whether a run links is decided by the KINDS --emit names, from the same
// parse codegen uses. An empty item names no kind and a repeat names
// the same kind again, so `obj,`, `,obj` and `obj,obj` are `obj` (they link)
// and `asm,asm` is `asm` (it stops at assembly, and -o names the .s). The
// linker options must not count comma runs instead: `obj, -o app` would write an
// object to app, `obj,obj` with no -o would link nothing, and `asm,asm -o x.s`
// would link an executable into x.s.

fn main() -> i32 { return 3 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d/dup
// RUN: %kairo %s --emit=obj, -o %t.d/trail --cache-dir %t.d/k1
// RUN: %t.d/trail; test $? -eq 3
// RUN: %kairo %s --emit=,obj -o %t.d/lead --cache-dir %t.d/k2
// RUN: %t.d/lead; test $? -eq 3
// RUN: cd %t.d/dup && %kairo %s --emit=obj,obj --cache-dir %t.d/k3
// RUN: %t.d/dup/a.out; test $? -eq 3
// RUN: %kairo %s --emit=asm,asm -o %t.d/one.s --cache-dir %t.d/k4
// RUN: %FileCheck %s --input-file=%t.d/one.s --check-prefix=ASM
// ASM: {{^_?main:}}
