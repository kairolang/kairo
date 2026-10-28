// adt/generic_tag_eq.k -- exit 0
// `==` on two values of one generic ADT inside a generic body: the enum
// declares no `op ==`, so it is the tag compare (enums-adt.mdx), which needs
// nothing from the instance's arguments. The layout is the instance's, so
// the variant is read through `__kairo_which()` (EnumLayoutQuery's Opaque
// shape), which both of C++'s layouts answer. It used to reach EmitIR as a
// record `==` and ICE ("user operator; OperatorLowering must rewrite it").
enum <T> Opt {
    Some { v: T },
    None,
}

fn <T> same(a: Opt<T>, b: Opt<T>) -> bool = a == b
fn <T> differ(a: Opt<T>, b: Opt<T>) -> bool = a != b

fn main() -> i32 {
    var r = 0
    var seven: i64 = 7
    if !same(Opt<i32>::Some { v: 1 }, Opt<i32>::Some { v: 2 }) { r += 1 }   // tags only
    if same(Opt<i32>::Some { v: 1 }, Opt<i32>::None)           { r += 2 }
    if !differ(Opt<i64>::None, Opt<i64>::Some { v: seven })    { r += 4 }
    if differ(Opt<i64>::None, Opt<i64>::None)                  { r += 8 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __kairo_which()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
