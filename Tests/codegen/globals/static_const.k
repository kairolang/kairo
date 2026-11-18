// `static const` (either order) at each scope, seen from C++. The const is
// the binding's, so it lands where `const` would: in the declarator of a
// namespace-scope variable (`int const A`, `int *const P`), before the type
// of a function-local `static` (`static const int L`), and on both the
// in-class declaration and the inline definition of a `static const`
// member -- C++ rejects a definition whose type drops it.

static const A = 10
const static B: i32 = 20
static G: i32 = 7
static const *P = &G

module m {
    pub const static MA = 3
}

class K {
    pub static const KA: i32 = 4
    pub const static KB: i32 = 5
}

fn f() -> i32 {
    static const LA = 1
    const static LB = 2
    return LA + LB
}

fn main() -> i32 {
    (*P) = 8
    return A + B + G + m::MA + K::KA + K::KB + f()   // 10+20+8+3+4+5+3 == 53
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF-LABEL: CODEGEN C++: {{.*}}static_const.k
// DEF: {{^ *}}public: static const signed int KA;
// DEF-NEXT: {{^ *}}static const signed int KB;
// DEF: {{^ *}}inline constinit const signed int K::KA = 4;
// DEF-NEXT: {{^ *}}inline constinit const signed int K::KB = 5;
// DEF: {{^ *}}extern signed int const A;
// DEF: {{^ *}}extern signed int const B;
// DEF: {{^ *}}extern signed int{{ ?}}*{{ ?}}const P;
// DEF: {{^ *}}extern signed int const MA;
// DEF: {{^ *}}signed int const A = 10;
// DEF: {{^ *}}signed int const B = 20;
// DEF: {{^ *}}signed int{{ ?}}*{{ ?}}const P ={{.*}}::static_const::G
// DEF: {{^ *}}signed int const MA = 3;
// DEF: {{^ *}}static const signed int LA = 1;
// DEF-NEXT: {{^ *}}static const signed int LB = 2;

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 53
