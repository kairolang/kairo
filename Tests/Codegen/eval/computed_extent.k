// EVAL.md 0.2 / 3 / 5: an array length or generic value argument Sema
// cannot fold is kept as an interned expression over value parameters,
// eval names and eval calls, and C++ computes it: `[i32; N + 1]`,
// `Buf<M * 2>`, `[i32; twice(3)]`, `Buf<twice(1)>`, and an `eval for`
// binding as a length. Under an instance the expression folds again once
// its parameters are values, so `Buf<3>`'s `[i32; N + 1]` IS `[i32; 4]`
// (take4 accepts it).

eval fn twice(x: usize) -> usize { return x * 2 }
eval HALF = twice(2)

class <eval N: usize> Buf {
    pub var data: [i32; N + 1]
    fn Buf(self) { }
    fn cap(const self) -> usize { return N + 1 }
}

fn <eval M: usize> more() -> usize {
    var b = Buf<M * 2>()
    return b.cap()
}

fn take4(const a: [i32; 4]) -> i32 { return a[3] }

fn main() -> i32 {
    var b = Buf<3>()
    b.data[3] = 7
    var c: [i32; twice(3)] = [1, 2, 3, 4, 5, 6]
    var d: [i32; HALF + 1] = [1, 2, 3, 4, 5]
    var t = 0
    eval for i in 0..3 {
        var a: [i32; i + 1]
        a[i] = 1
        t += a[i]
    }
    var e = Buf<twice(1)>()
    var f = Buf<2>()                     // the same C++ specialization as e's
    return take4(b.data) + c[5] + d[4] + t + (more<2>() as i32) + (e.cap() as i32) + (f.cap() as i32)
        // 7 + 6 + 5 + 3 + 5 + 3 + 3 == 32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}computed_extent.k
// IR:      template<decltype(sizeof(0)) N> class Buf {
// IR-NEXT:     public: signed int data[(N + 1)] {
// IR-NEXT:     };
// IR:      ::computed_extent::Buf<(M * 2)> b =
// IR:      signed int c[ ::computed_extent::twice(3)] =
// IR:      signed int d[( ::computed_extent::HALF + 1)] =
// IR:      signed int a[(i + 1)]
// IR:      ::computed_extent::Buf< ::computed_extent::twice(1)> e =
// No explicit instantiation over a computed value: Buf<2> has its own.
// IR:      template class{{ ?}}::computed_extent::Buf<2>;
// IR-NOT:  template class{{.*}}twice

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 32
