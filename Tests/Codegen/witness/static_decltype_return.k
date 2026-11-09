// witness/static_decltype_return.k -- exit 0
// A requirement whose return type C++ spells with parentheses of its own
// (`-> usize` is `decltype(sizeof(0))`) gets a well-formed member-pointer
// gate in the witness. The gate's type was made by splitting the signature
// at its first `(`, which for usize is inside the decltype:
// `static_cast<decltype(*)(sizeof(0))()>`, and clang rejected the file. The
// return now goes trailing, for a static and for a method requirement.

interface Scoped {
    static fn enter() -> usize
    static fn leave(mark: usize)
    fn depth(const self) -> usize
}

class Arena impl Scoped {
    var d: usize
    static fn enter() -> usize { return 5 }
    static fn leave(mark: usize) { }
    fn depth(const self) -> usize { return self.d }
}

fn <A impl Scoped> open(a: A) -> usize {
    var m = A::enter()
    A::leave(m)
    return m + a.depth()
}

fn main() -> i32 {
    var a = Arena()
    a.d = 2
    return if open(a) == 7 => 0 else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: static_cast<auto(*)()->decltype(sizeof(0))>(& __kairo_Self::enter);
// CXX-DAG: static_cast<auto(*)(decltype(sizeof(0)))->void>(& __kairo_Self::leave);
// CXX-DAG: static_cast<auto(__kairo_Self::*)() const->decltype(sizeof(0))>(& __kairo_Self::depth);

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=NEG
// NEG-NOT: decltype(*)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
