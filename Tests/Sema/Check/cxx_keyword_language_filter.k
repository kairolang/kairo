// SC004E rejects a name only if C++ would: `out`, `inout` and
// `groupshared` are keywords to clang only in HLSL, `kernel` only in OpenCL,
// and `int out;` is valid C++. The keyword set used to take every kind clang
// has a keyword spelling for, in any language, so these were errors. A real
// C++ keyword (`signed`) still is, and the message names it.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: SC004E
// CHECK: cxx_keyword_language_filter.k:[[@LINE+14]]:9: error [SC004E]: variable name 'signed' is a C++ keyword; Kairo names are emitted unchanged, so C++ cannot declare or name it
// CHECK-NOT: error

fn fill(out: *i32) -> i32 { return 0 }

fn g() -> i32 {
    var out = 1
    var inout = 3
    var groupshared = 4
    var kernel = 5
    return out + inout + groupshared + kernel
}

fn h() -> i32 {
    var signed = 1
    return 0
}
