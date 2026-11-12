// --no-cxx and the ffi language word. The gate asks the parser's
// table (Statements::ffi_lang_of), matched without case, so every word the
// parser takes as C++ is denied ("cpp", "C++", "hpp"), not only a spelling
// that ends in "c++"; and "C" is C to the preprocessor as it is to the
// parser, so an `ffi "C" import` stays legal under --no-cxx like
// `ffi "c"` does.

ffi "cpp" {
    fn kt_one() -> i32
}

ffi "C++" {
    fn kt_two() -> i32
}

ffi "hpp" {
    fn kt_three() -> i32
}

ffi "C" {
    fn kt_four() -> i32
}

ffi "C" import "stdlib.h"

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-cxx %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_cxx_ffi_words.k:8:1: error [SC198E]: an ffi "c++" block is not allowed when C++ interop is disabled
// CHECK: no_cxx_ffi_words.k:12:1: error [SC198E]: an ffi "c++" block is not allowed when C++ interop is disabled
// CHECK: no_cxx_ffi_words.k:16:1: error [SC198E]: an ffi "c++" block is not allowed when C++ interop is disabled
// CHECK-NOT: error
