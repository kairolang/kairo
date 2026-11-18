//
// Library defect: `x in v` (the containment operator) is rejected on a
// vector and on a slice. The slice declares `op in (const self, const v: T)`
// in its `Eq` extension, but its own iteration `op in` hides it at the call:
// "no matching overload for call to 'op in'... expects 0 argument(s), 1
// given". `v.contains(x)` is the same search under a method name.
//
// Cases from libc++ test/std/containers/sequences/vector/compare.pass.cpp
//   (membership of an element)

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [i32;] = v
    var bad: i32 = 0
    if !(4 in s) {
        bad += 1
    }

    if !(4 in v) {
        bad += 1
    }

    if 9 in v {
        bad += 1
    }

    return bad
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
