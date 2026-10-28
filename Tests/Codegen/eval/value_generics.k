// Generic value parameters, `<eval N: T>` (EVAL.md 3), on classes and
// functions: an argument is folded like an array length (a literal, an
// eval constant, arithmetic over them), so `Ring<CAP + 1, i32>` IS
// `Ring<4, i32>`; `[T; N]` takes its extent from the parameter; `N` is a
// value of its declared type; a function's value parameter is given
// explicitly (`width<5>()`) or deduced from an array extent.
eval CAP = 3

class <eval N: usize, T> Ring {
    pub var items: [T; N]
    fn size(const self) -> usize { return N }
    fn twice(const self) -> usize { return N * 2 }
}

class <eval K: i32> Neg { fn k(const self) -> i32 { return K } }

fn <eval M: usize> width() -> usize { return M * 2 }
fn <eval L: usize> first_plus_len(const a: [i32; L]) -> i32 { return a[0] + (L as i32) }

fn main() -> i32 {
    var a = Ring<4, i32>()
    var b = Ring<CAP + 1, i32>()                // the same instance as a's
    a = b
    var c = Ring<CAP, i64>()
    var n = Neg<-3>()
    var arr: [i32; 3] = [10, 20, 30]
    return (a.size() + c.twice() + width<5>()) as i32 + n.k() + first_plus_len(arr)
        // 4 + 6 + 10 - 3 + 13 == 30
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}value_generics.k
// IR:     template<decltype(sizeof(0)) N, class T> class Ring {
// IR-NEXT:    T items[N];
// IR:     Ring<4, signed int> a =
// IR:     Ring<4, signed int> b =
// IR:     Neg<- 3> n =
// IR:     width<5>()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 30
