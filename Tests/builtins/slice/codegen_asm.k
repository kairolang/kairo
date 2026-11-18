// Properties of the -O2 x86-64 code for slices: an index the optimizer
// cannot prove keeps exactly one compare and one call to the cold failure
// function; a counted loop over the indices keeps no check and vectorizes;
// `for x in s` vectorizes with no check; a slice passes and returns in two
// registers, with no sret; reverse and contains vectorize for word and
// half-word elements.

fn at(const s: [i32;], i: usize) -> i32 {
    return s[i]
}

fn counted(const s: [i32;]) -> i32 {
    var t = 0
    for var i: usize = 0; i < s.size(); i += 1 {
        t += s[i]
    }

    return t
}

fn sum(const s: [i32;]) -> i32 {
    var t = 0
    for x in s {
        t += x
    }

    return t
}

fn pass(s: [u64;]) -> [u64;] {
    return s
}

fn rev(s: [u64;]) {
    s.reverse()
}

fn has(const s: [u32;], v: u32) -> bool {
    return s.contains(v)
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %s -O2 --target=x86_64-linux-gnu -S -o %t.d/out.s --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.s
// CHECK-LABEL: _ZN11codegen_asm2atE{{.*}}:
// CHECK:       cmpq
// CHECK-NEXT:  jae
// CHECK-NOT:   call
// CHECK:       retq
// CHECK-NOT:   cmpq
// CHECK:       callq {{.*}}index_fail
// CHECK-NEXT:  .Lfunc_end
// CHECK-LABEL: _ZN11codegen_asm7countedE{{.*}}:
// CHECK-NOT:   index_fail
// CHECK:       paddd
// CHECK:       .Lfunc_end
// CHECK-LABEL: _ZN11codegen_asm3sumE{{.*}}:
// CHECK-NOT:   index_fail
// CHECK:       paddd
// CHECK:       .Lfunc_end
// CHECK-LABEL: _ZN11codegen_asm4passE{{.*}}:
// CHECK:       # %bb.0:
// CHECK-NOT:   (%rdi)
// CHECK-DAG:   movq %rdi, %rax
// CHECK-DAG:   movq %rsi, %rdx
// CHECK:       retq
// CHECK-LABEL: _ZN11codegen_asm3hasE{{.*}}:
// CHECK:       pcmpeqd
// CHECK:       .Lfunc_end
// CHECK-LABEL: {{^}}_ZN7builtin10containers5slice12sort_revswapImEEvPT_S4_m:
// CHECK:       pshufd
// CHECK:       .Lfunc_end
