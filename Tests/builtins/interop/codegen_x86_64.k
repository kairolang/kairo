// What the conversions cost at -O2 on x86-64. The view of a string is its
// pointer and its length: two loads and a shift, with no call and no branch,
// so it is the same for every state. `into_cxx()` on a `[i32]` allocates the
// C++ block once and copies every element with one memcpy, then frees the
// Kairo block; nothing is pushed one by one.

ffi "c++" import "string_view"
ffi "c++" import "vector"

@no_inline pub fn to_view(const s: string) -> cxx::std::string_view {
    return s
}

@no_inline pub fn vec_out(v: [i32]) -> cxx::std::vector<i32> {
    return v.into_cxx()
}

fn main() -> i32 {
    var s = "abc"
    var v = Vector<i32>()
    v.push(1)
    return (to_view(s).size() + vec_out(v).size() - 4) as i32
}

// --- lit wiring ---
// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=asm -o %t.d/out.s --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.s

// CHECK-LABEL: {{^}}_ZN14codegen_x86_647to_viewE{{.*}}:
// CHECK-NOT:   {{^}}.Lfunc_end
// CHECK:       movq (%rdi), %rax
// CHECK-NEXT:  movq 8(%rdi), %rdx
// CHECK-NEXT:  shrq $3, %rdx
// CHECK-NEXT:  retq

// CHECK-LABEL: {{^}}_ZN14codegen_x86_647vec_outE{{.*}}:
// CHECK-NOT:   {{^}}.Lfunc_end
// CHECK:       callq _Znwm
// CHECK-NOT:   callq
// CHECK:       callq memcpy
// CHECK-NOT:   callq
// CHECK:       callq kairo_global_free
// CHECK-NOT:   callq {{.*}}emplace_back
// CHECK:       {{^}}.Lfunc_end
