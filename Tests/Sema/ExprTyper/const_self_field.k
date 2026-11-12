// In a `const self` method `self` is a const object, so a field reached
// from it through `.` is const too, as `this->f` is in a C++ const member
// function: writing it, or an element of it, is SC071E. A `mutable var`
// field is not const there (C++ `mutable`): it may be written, and the
// method compiles and runs.

class Counter {
    pub mutable var hits: i32 = 0
    pub var v: [i32] = [1, 2]
    pub fn Counter(self) { }
    pub fn touch(const self) -> i32 {
        self.hits = 10
        self.hits += 1
        return self.v[0]
    }
}

fn main() -> i32 {
    var c = Counter()
    var r = c.touch()
    return c.hits + r
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
// RUN: { %kairo %S/Inputs/const_self_field/writes.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: writes.k:9:32: error [SC071E]: cannot assign to 'y': 'self' is const in a 'const self' method
// CHECK-NEXT: writes.k:4:13: note [I900N]: 'y' is declared here; a 'mutable var' field may be written from a 'const self' method
// CHECK: writes.k:10:33: error [SC071E]: cannot update 'y': 'self' is const in a 'const self' method
// CHECK: writes.k:11:35: error [SC071E]: cannot assign to a const place
