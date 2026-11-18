// `unsafe const &x` is the address of `x` as an `unsafe *const T`: the
// words come in the order of the type they make. `const unsafe &x` is
// S096E with the swap as its fix-it, and parses as what it meant, so the
// fixed file compiles. `const` before anything but `&` begins no
// expression.

fn main() -> i32 {
    var a = 1
    var p: unsafe *const i32 = const unsafe &a
    var q = const a
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: const_addr_misordered.k:9:32: error [S096E]: 'unsafe' comes before 'const' in an address-of: write 'unsafe const &x', as the type is 'unsafe *const T'
// CHECK-NEXT: fix-it:"{{.*}}const_addr_misordered.k":{9:32-9:44}:"unsafe const"
// CHECK: const_addr_misordered.k:10:13: error [S052E]: expected expression, found 'const'
//
// RUN: rm -rf %t && mkdir -p %t && sed -e '/var q = const a/d' %s > %t/m.k
// RUN: { %kairo %t/m.k --syntax-only 2>&1 || true; } > %t/diag.txt
// RUN: python3 %S/../../../Scripts/apply_fixits.py --from %t/diag.txt 2>&1 | %FileCheck %s --check-prefix=APPLIED
// RUN: grep -c "unsafe const &a" %t/m.k
// RUN: %kairo %t/m.k -w -o %t/m.exe --cache-dir %t/c
// RUN: %t/m.exe
//
// APPLIED: changed 1 file(s)
