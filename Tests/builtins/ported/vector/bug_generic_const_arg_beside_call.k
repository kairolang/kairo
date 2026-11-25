// Compiler defect: in a generic function, passing a vector variable to a
// `const` parameter together with a second argument that is a call returning
// a vector makes the emitted C++ copy the variable, and the program is
// rejected: "call to implicitly-deleted copy constructor of Vector<int>".
// The same calls compile in a non-generic function, and in the generic one
// when the call is the only argument.
//
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_cmp: compare a vector with a freshly built vector)

fn other() -> [i64] {
    var out: [i64]
    return out
}

fn <E> same_size(const v: [E], const x: [i64]) -> bool {
    return v.size() == x.size()
}

fn <E> check(v: [E]) -> bool {
    var same = same_size(v, other())
    var p? = v.pop()
    return same && p?
}

fn main() -> i32 {
    var v: [i32] = [1]
    return if check(v.copy()) => 1 else => 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
