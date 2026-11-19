// `[const X;]` is the library's `Slice<const T>` specialization. A loop over
// one reads `first_()` and `count_()` of that specialization, the members
// clang resolves, and the instance reaches what the specialization's own
// members name: `to_owned()` is a `[X]`, never a `Vector<const X>`.
fn sum(const xs: [const i32;]) -> i32 {
    var n = 0
    for x in xs {
        n += x
    }

    return n
}

fn main() -> i32 {
    var xs: [i32] = [1, 2, 3]
    var view: [const i32;] = xs
    return sum(view) - 6
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=AGREE --allow-empty
// AGREE-NOT: I012W
// AGREE-NOT: error [

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: Vector<const
// CXX:     Slice<const signed int>
// CXX-NOT: Vector<const
