import lib::*

// EVAL.md §11 (USER): a compile-time string literal longer than 256 bytes
// is not `::__kairo_estr<b0, b1, ...>` (one template argument per byte) but
// `::__kairo_estrh_<len>_<hash>`, an `inline constexpr unsigned char[]`
// named for its content and defined at global scope ahead of every body
// and type that spells it. Equal literals are one entity in every TU and
// header, so lib's BIG and this file's MINE share their bytes once linked,
// and a short literal keeps the byte template.
eval MINE = "Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! Kairo eval! "

fn main() -> i32 {
    var r = BIG.len + MINE.len + big_len() + SHORT.len     // 300 * 3 + 5
    if BIG.data == MINE.data { r += 1 }                   // one object
    if BIG.data[299] == 32 { r += 1 }
    if MINE.data[300] == 0 { r += 1 }                     // the NUL it carries
    return (r - 900) as i32                                 // 5 + 3 == 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}lib.k
// IR:      inline constexpr unsigned char __kairo_estrh_300_[[H:[0-9a-f]+]][301] = {
// IR-NEXT:  75, 97, 105, 114, 111,
// IR-NOT:  __kairo_estrh_300_
// IR:      ::builtin::string::string( ::__kairo_estrh_300_[[H]], 300, 300).len;
// IR:      inline constexpr::builtin::string::string const BIG = ::builtin::string::string( ::__kairo_estrh_300_[[H]], 300, 300);
// IR:      inline constexpr::builtin::string::string const SHORT = ::builtin::string::string( ::__kairo_estr<115, 104, 111, 114, 116>, 5, 5);
// IR-LABEL: CODEGEN C++: {{.*}}use.k
// IR:      inline constexpr unsigned char __kairo_estrh_300_[[H]][301] =
// IR-NOT:  inline constexpr unsigned char __kairo_estrh_300_
// IR:      inline constexpr::builtin::string::string const MINE = ::builtin::string::string( ::__kairo_estrh_300_[[H]], 300, 300);

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/c
// RUN: %t.exe; test $? -eq 8

// The header guards its definition; kcc's `#include "lib.k"` in two C++
// TUs, linked with lib's own object, defines the array three times as one
// inline entity: no duplicate symbol.
// RUN: %kairo %S/lib.k --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/lib.hh
// HDR: #ifndef __KAIRO_ESTRH_300_[[G:[0-9a-f]+]]
// HDR-NEXT: #define __KAIRO_ESTRH_300_[[G]]
// HDR-NEXT: inline constexpr unsigned char __kairo_estrh_300_[[G]][301] =
// HDR: #endif
// REQUIRES: kcc
// RUN: cd %S && %kcc -c lib.k -o %t.d/lib.o
// RUN: cd %S && %kcc -c host.cc -o %t.d/host.o
// RUN: cd %S && %kcc -c host.cc -DSECOND -o %t.d/host2.o
// RUN: %kcc %t.d/host.o %t.d/host2.o %t.d/lib.o -o %t.d/app && %t.d/app; test $? -eq 42
