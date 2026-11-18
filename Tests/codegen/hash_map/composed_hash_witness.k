// An interface that composes Hash is met the way Hash is: the `hash`
// requirement it takes from Hash stands as its own witness on an imported
// C++ type (`std::hash<X>`) and on a pointer (its address). EmitWitness
// spells those two forms for that requirement only; any other named
// requirement left as its own witness is an internal error there.
ffi "c++" import "cxx_key.h"

interface OnlyHash derives Hash { }

fn <T impl OnlyHash> h(const x: T) -> usize { return x.hash() }

fn main() -> i32 {
    var a: i32 = 1
    if h(make_key(1, 2)) != h(make_key(1, 2)) { return 1 }
    if h(make_key(1, 2)) == h(make_key(2, 1)) { return 2 }
    if h(&a) != h(&a) { return 3 }
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<> struct OnlyHash_witness< ::CxxKey> {
// CXX: return static_cast<decltype(sizeof(0))>( ::std::hash< ::CxxKey> {
// CXX: template<> struct OnlyHash_witness<signed int *> {
// CXX: return reinterpret_cast<decltype(sizeof(0))>(* self);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100
