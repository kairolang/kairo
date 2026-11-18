// FFI in a serialized AST, as far as the parser sees it:
//
//   - `ffi "c++" import "header"` is an ImportDecl the preprocessor took
//     out of the token stream (tu->imports, in pp_alloc), carrying the
//     header's string literal and the language token. The header's own fid
//     and include closure are the driver's, written during Sema, and are
//     not part of a parsed tree.
//   - `ffi "c" { ... }` is an FFIBlockDecl; each declaration in it carries
//     the FFILinkage stamp (kind, range, the language string's token).
//   - `ffi "c" fn` stamps one declaration.
//
// Under --ast-roundtrip the reloaded ImportDecls are the ones phase I
// reads, so the header's names must still resolve.

ffi "c++" import "vector"
ffi "c" import "string.h" as cstr

ffi "c" {
    fn kairo_test_first(x: i32) -> i32
    fn kairo_test_second(x: i64) -> i64

    struct div_pair {
        var quot: i32
        var rem:  i32
    }
}

ffi "c" fn kairo_test_third(s: unsafe *const i8) -> i32

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(4)
    return (v.size() as i32) - 1
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --syntax-only --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY --allow-empty
// VERIFY-NOT: I002F
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } > %t.parsed
// RUN: { %kairo %s --syntax-only --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s < %t.reloaded
// CHECK: FFIBlockDecl
//
// The imports are the reloaded ones: --print-imports is after preprocessing
// (before the round trip), --print-sema after phase I folded them.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag.parsed
// RUN: { %kairo %s --type-check-only --ast-roundtrip 2>&1 || true; } > %t.diag.reloaded
// RUN: diff %t.diag.parsed %t.diag.reloaded
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } > %t.sema.parsed
// RUN: { %kairo %s --type-check-only --print-sema --ast-roundtrip 2>&1 || true; } > %t.sema.reloaded
// RUN: diff %t.sema.parsed %t.sema.reloaded
