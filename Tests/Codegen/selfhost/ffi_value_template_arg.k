// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// An imported C++ class template with a non-type argument:
// `std::array<i32, 4>` (and llvm::SmallVector<T, N>, which Compiler/
// imports in 8 files).
//
// This used to fail twice over. The bare declaration ICEd, "EmitIR:
// unresolved type reached codegen"; once value arguments had a canonical
// (CanonicalTypeStore::value_arg), the instance still could not be FILLED
// from clang -- "template argument 1 has no clang spelling in phase A" --
// so `a[1]` was looked up on the pattern, where `operator[]` and its const
// twin tie (SC064E). TypeExport now spells the value as a template argument
// of the parameter's type, and TypeImport reads clang's Integral arguments
// back. More shapes: Codegen/ffi_value_args/.

ffi "c++" import "array"

fn main() -> i32 {
    var a: cxx::std::array<i32, 4>
    a[1] = 5
    return a[1] + (a.size() as i32)           // 5 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
