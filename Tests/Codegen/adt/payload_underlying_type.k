// A payload enum with a declared underlying type (enums-adt.mdx; enums-
// plain.mdx, `derives u8`): the tag is that type, so `E` below is a u8 tag
// and a u8 payload, two bytes, and `W`'s u16 tag makes it four although its
// two variants would fit the u8 tag an undeclared one gets.
//
// Was XFAIL on the ticket "[Sema/Codegen] A payload enum's declared
// underlying type is ignored" (private/IMPORTANT/TICKETS.TXT, GitHub #98):
// the tag was always u32 and `sizeof E` 8.

enum E derives u8 {
    A { x: u8 },
    B,
}

enum W derives u16 {
    A { x: u8 },
    B,
}

enum D {
    A { x: u8 },
    B,
}

fn main() -> i32 {
    var r = 0
    if sizeof E == 2 { r += 1 }
    if sizeof W == 4 { r += 2 }
    if sizeof D == 2 { r += 4 }
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}payload_underlying_type.k
// CXX:       struct E {
// CXX-NEXT:  enum class __kairo_Tag : unsigned char {
// CXX:       struct W {
// CXX-NEXT:  enum class __kairo_Tag : unsigned short {
// CXX:       struct D {
// CXX-NEXT:  enum class __kairo_Tag : unsigned char {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
