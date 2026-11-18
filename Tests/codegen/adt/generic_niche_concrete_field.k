// A niche-shaped generic ADT whose one payload field names no parameter
// (`enum <T> GK { A { x: i32 }, B }`): every instance has the same verdict,
// and the niche-filled partial specialization beside the template is not
// dependent, so clang checks its body where it is written. With a field
// that has no niche (`i32`, a struct) `__kairo_niche<int>::pattern` would be an
// error at GK's declaration, for every use, so such an ADT is a
// plain tagged generic one; a concrete field WITH a niche (a pointer)
// keeps the niche-filled layout.

struct St { var a: i32 }
enum <T> GK { A { x: i32 }, B }
enum <T> GS { A { s: St }, B }
enum <T> GP { A { p: unsafe *i32 }, B }

fn main() -> i32 {
    var k: GK<i32> = GK<i32>::A { x: 7 }
    var s: GS<u8>  = GS<u8>::B
    var p: GP<i32> = GP<i32>::B
    if sizeof GK<i32> != 8 { return 1 }
    if sizeof GS<u8> != 8 { return 2 }
    if sizeof GP<i32> != 8 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// No niche specialization for the two fields without a niche; the pointer's
// stays.
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-NOT: requires( ::__kairo_niche<signed int>::count
// IR-NOT: requires( ::__kairo_niche< ::{{.*}}::St>::count
// IR: requires( ::__kairo_niche<signed int *>::count

// REQUIRES: default-sysroot
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
