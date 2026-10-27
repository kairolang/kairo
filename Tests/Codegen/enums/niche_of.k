// `__builtin_niche_of<T>()` (spec ENUMLAYOUT §5.1) is the layout engine's
// niche_of, answered at compile time: each call becomes a `u64` literal. 1
// for a pointer, the values past an ADT tag's, those left by a niche-filled
// ADT, a record's first field's, 0 otherwise (a plain enum: `as` makes any
// value of its word).

enum Color derives u8 { Red, Green, Blue }
struct P { var a: i32 = 0; var p: *i32; }
enum Inst { A { x: i32 }, B }
enum Spread { Lo = 1, Hi = 5 }

fn main() -> i32 {
    var r = 0
    if __builtin_niche_of<*i32>() == 1     { r += 1 }
    if __builtin_niche_of<Color>() == 0    { r += 2 }    // a plain enum: none
    if __builtin_niche_of<i32>() == 0      { r += 4 }    // bool and integers: none
    if __builtin_niche_of<Inst>() == 254   { r += 8 }    // its u8 tag: 256 - 2
    if __builtin_niche_of<P>() == 1        { r += 16 }   // its pointer field's
    if __builtin_niche_of<(*i32)?>() == 0  { r += 32 }   // the null took the only one
    if __builtin_niche_of<Color?>() == 254 { r += 64 }   // tagged: its u8 tag's
    if (__builtin_niche_of<Spread>() == 0) && (__builtin_niche_of<bool>() == 0) { r += 128 }
    return r                                // 255
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}niche_of.k
// IR-NOT:   __builtin_niche_of
// IR:       if(0 == 0) {
// IR-NOT:   __builtin_niche_of

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 255
