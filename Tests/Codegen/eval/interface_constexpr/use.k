import lib::*

// EVAL.md 1.2b: an eval binding is `inline constexpr`, and its definition
// is part of the interface -- an importer's `extern const` is no constant
// expression, so `M = N + 1` needs N defined here. Each TU writes the
// definitions it reads, dependencies first (lib's NEXT reads N, declared
// below it), in Kairo TUs, in the header, and in a kcc `#include "lib.k"`.
eval M = N + 1
eval LABEL = TAG

fn main() -> i32 {
    var a: [i32; K] = [1, 2, 3]
    return M + NEXT + a[2] + LABEL.len as i32     // 9 + 9 + 3 + 3 == 24
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}lib.k
// IR:      extern signed int const N;
// IR:      inline constexpr signed int const N = ::lib::cube(2);
// IR:      inline constexpr signed int const NEXT =( ::lib::N + 1);
// IR-LABEL: CODEGEN C++: {{.*}}use.k
// IR:      extern signed int const N;
// IR:      consteval signed int cube(signed int x) noexcept {
// IR:      inline constexpr signed int const N = ::lib::cube(2);
// IR:      inline constexpr signed int const NEXT =( ::lib::N + 1);
// IR:      inline constexpr signed int const M =( ::lib::N + 1);

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/c
// RUN: %t.exe; test $? -eq 24

// The header (`--emit-headers`) and kcc's `#include "lib.k"`: C++ reads
// the constants in static_asserts and an array bound (host.cc).
// RUN: %kairo %S/lib.k --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/lib.hh
// HDR: extern signed int const N;
// HDR: consteval signed int cube(signed int x) noexcept {
// HDR: inline constexpr signed int const N ={{ ?}}::lib::cube(2);
// HDR: inline constexpr signed int const NEXT ={{.*}}::lib::N + 1);
// REQUIRES: kcc
// RUN: cd %S && %kcc -c lib.k -o %t.d/lib.o
// RUN: cd %S && %kcc -c host.cc -o %t.d/host.o
// RUN: %kcc %t.d/host.o %t.d/lib.o -o %t.d/app && %t.d/app; test $? -eq 42
