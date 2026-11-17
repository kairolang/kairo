// What strings used as keys and as copies compile to at -O2 on x86-64 SysV,
// read off the LLVM IR. `<` orders two strings by their first words read as
// integers; what follows an equal first word, and a side shorter than a
// word, are compared in the string library, so the caller itself calls no
// byte compare. `codepoints()` tests the heap state first and reaches the
// count word by a subtract, with no test of the ASCII bit and no call
// before it. A slice that is only copied is never stored: no stack slot,
// and no free for the view.

fn less(const a: string, const b: string) -> bool {
    return a < b
}

fn count(const s: string) -> usize {
    return s.codepoints()
}

fn cut(const s: string, n: usize) -> string {
    return s[0..n].to_owned()
}

fn main() -> i32 {
    var s = "abcdefgh-1"
    var t = "abcdefgh-2"
    if !less(s, t) {
        return 1
    }

    return (count(cut(s, 4)) - 4) as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// REQUIRES: sysroot-x86_64-linux-gnu
// REQUIRES: sysroot-armv7-linux-musl
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll
// RUN: %kairo_new %s -O2 --target=armv7-linux-musl --emit=llvm-ir -o %t.d/arm.ll --cache-dir %t.d/arm
// RUN: %FileCheck %s --check-prefix=W4 --input-file=%t.d/arm.ll

// CHECK-LABEL: define {{.*}}4lessE
// CHECK-NOT:   {{ call .*(memcmp|bcmp)}}
// CHECK:       call {{.*}}@llvm.bswap.i64
// CHECK-NOT:   {{ call .*(memcmp|bcmp)}}
// CHECK:       call {{.*}}compare_rest_
// CHECK-NOT:   {{ call .*(memcmp|bcmp)}}
// CHECK:       ret i1

// CHECK-LABEL: define {{.*}}5countE
// CHECK-NOT:   {{ call }}
// CHECK-NOT:   and i64 %{{.*}}, 4
// CHECK:       sub i64
// CHECK:       ret i64

// CHECK-LABEL: define {{.*}}3cutE
// CHECK-NOT:   alloca
// CHECK-NOT:   free
// CHECK:       call {{.*}}to_owned_
// CHECK-NOT:   free
// CHECK:       ret { ptr, i64 }

// With a four-byte word the first-word compare is of 32-bit words.
// W4-LABEL: define {{.*}}4lessE
// W4:       call {{.*}}@llvm.bswap.i32
// W4:       ret i1
