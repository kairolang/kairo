// A qualified pattern argument (`const P`, `*const P`) is its
// own partial specialization, more specialized than the unqualified one, and
// deduction binds P to the argument without the matched qualifier.

class <T> V { var n: i32 = 1 }
class <P> V<const P> { var n: i32 = 2 }
class <P> V<*P> { var n: i32 = 3 }
class <P> V<*const P> { var n: i32 = 4 }

extend <T> V<T> {
    fn size(const self) -> i32 { return self.n }
}

class <T> Slice {
    var data: *T
    var len:  usize
    fn Slice(self, d: *T, n: usize) { self.data = d; self.len = n }
    fn get(const self, i: usize) -> *const T { return self.data }
    fn set(self, i: usize, const v: T) { *self.data = v }
}

class <T> Slice<const T> {
    var data: *const T
    var len:  usize
    fn Slice(self, d: *const T, n: usize) { self.data = d; self.len = n }
    fn get(const self, i: usize) -> *const T { return self.data }

    // Reassigning a local `T` compiles only when T is the unqualified element.
    fn first(const self) -> T {
        var t: T = *self.data
        t = *self.data
        return t
    }
}

fn main() -> i32 {
    var a: V<i32>
    var b: V<const i64>
    var c: V<*i32>
    var d: V<*const i32>
    if a.size() != 1 || b.size() != 2 || c.size() != 3 || d.size() != 4 {
        return 1
    }

    var x: i32 = 41
    var m = Slice<i32>(&x, 1)
    m.set(0, 5)
    var k = Slice<const i32>(&x, 1)
    if k.first() != 5 || *m.get(0) != 5 {
        return 2
    }

    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: class V<const P>
// CXX-DAG: class Slice<const T>
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
